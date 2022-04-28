import macros, strformat, faststreams/async_backend, itertools,
  faststreams/asynctools_adapters, faststreams/inputs, faststreams/outputs,
  json_rpc/streamconnection, os, sugar, sequtils, hashes, osproc,
  suggestapi, protocol/enums, protocol/types, with, tables, strutils, sets,
  ./utils, ./pipes, chronicles, std/re, uri, "$nim/compiler/pathutils"

const
  STORAGE = getTempDir() / "nimlangserver"
  RESTART_COMMAND = "nimlangserver.restart"

discard existsOrCreateDir(STORAGE)

type
  NlsNimsuggestConfig = ref object of RootObj
    projectFile: string
    fileRegex: string

  NlsConfig = ref object of RootObj
    projectMapping*: OptionalSeq[NlsNimsuggestConfig]
    checkOnSave*: Option[bool]
    nimsuggestPath*: Option[string]
    timeout*: Option[int]

  LanguageServer* = ref object
    clientCapabilities*: ClientCapabilities
    initializeParams*: InitializeParams
    connection: StreamConnection
    projectFiles: Table[string, tuple[nimsuggest: Future[Nimsuggest],
                                      openFiles: OrderedSet[string]]]
    openFiles: Table[string, tuple[projectFile: Future[string],
                                   fingerTable: seq[seq[tuple[u16pos, offset: int]]]]]
    cancelFutures: Table[int, Future[void]]
    workspaceConfiguration: Future[JsonNode]
    filesWithDiags: seq[string]

  Certainty = enum
    None,
    Folder,
    Cfg,
    Nimble

macro `%*`*(t: untyped, inputStream: untyped): untyped =
  result = newCall(bindSym("to", brOpen),
                   newCall(bindSym("%*", brOpen), inputStream), t)

proc partial*[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe.}, a: A):
    proc (b: B) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b)

proc partial*[A, B, C] (fn: proc(a: A, b: B, id: int): C {.gcsafe.}, a: A):
    proc (b: B, id: int) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B, id: int): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b, id)

proc getProjectFileAutoGuess(fileUri: string): string =
  let file = fileUri.decodeUrl
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = None
  while path.len > 0 and path != "/":
    let
      (dir, fname, ext) = path.splitFile()
      current = fname & ext
    if fileExists(path / current.addFileExt(".nim")) and certainty <= Folder:
      result = path / current.addFileExt(".nim")
      certainty = Folder
    if fileExists(path / current.addFileExt(".nim")) and
      (fileExists(path / current.addFileExt(".nim.cfg")) or
      fileExists(path / current.addFileExt(".nims"))) and certainty <= Cfg:
      result = path / current.addFileExt(".nim")
      certainty = Cfg
    if certainty <= Nimble:
      for nimble in walkFiles(path / "*.nimble"):
        let info = execProcess("nimble dump " & nimble)
        var sourceDir, name: string
        for line in info.splitLines:
          if line.startsWith("srcDir"):
            sourceDir = path / line[(1 + line.find '"')..^2]
          if line.startsWith("name"):
            name = line[(1 + line.find '"')..^2]
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and
            file.isRelativeTo(sourceDir) and fileExists(projectFile):
          debug "Found nimble project", projectFile = projectFile
          result = projectFile
          certainty = Nimble
    path = dir

proc getWorkspaceConfiguration(ls: LanguageServer): Future[NlsConfig] {.async} =
  try:
    let nlsConfig: seq[NlsConfig] =
      (%await ls.workspaceConfiguration).to(seq[NlsConfig])
    result = if nlsConfig.len > 0: nlsConfig[0] else: NlsConfig()
  except CatchableError:
    debug "Failed to parse the configuration."
    result = NlsConfig()

proc getProjectFile(fileUri: string, ls: LanguageServer): Future[string] {.async} =
  let
    rootPath = AbsoluteDir(ls.initializeParams.rootUri.uriToPath)
    pathRelativeToRoot = string(AbsoluteFile(fileUri).relativeTo(rootPath))
    mappings = (await ls.getWorkspaceConfiguration).projectMapping.get(@[])

  for mapping in mappings:
    if find(cstring(pathRelativeToRoot), re(mapping.fileRegex), 0, pathRelativeToRoot.len) != -1:
      result = string(rootPath) / mapping.projectFile
      debug "getProjectFile", project = result, uri = fileUri, matchedRegex = mapping.fileRegex
      return result

  result = getProjectFileAutoGuess(fileUri)
  debug "getProjectFile", project = result

proc showMessage(ls: LanguageServer, message: string, typ: MessageType) =
  ls.connection.notify(
    "window/showMessage",
    %* {
         "type": typ.int,
         "message": message
    })

# Fixes callback clobbering in core implementation
proc `or`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  var retFuture = newFuture[void]("asyncdispatch.`or`")
  proc cb[X](fut: Future[X]) =
    if not retFuture.finished:
      if fut.failed: retFuture.fail(fut.error)
      else: retFuture.complete()
  fut1.addCallback(cb[T])
  fut2.addCallback(cb[Y])
  return retFuture

proc getCharacter(ls: LanguageServer, uri: string, line: int, character: int): int =
  return ls.openFiles[uri].fingerTable[line].utf16to8(character)

proc initialize(ls: LanguageServer, params: InitializeParams):
    Future[InitializeResult] {.async} =
  debug "Initialize received..."
  ls.initializeParams = params
  return InitializeResult(
    capabilities: ServerCapabilities(
      textDocumentSync: some(%TextDocumentSyncOptions(
        openClose: some(true),
        change: some(TextDocumentSyncKind.Full.int),
        willSave: some(false),
        willSaveWaitUntil: some(false),
        save: some(SaveOptions(includeText: some(true))))),
      hoverProvider: some(true),
      workspace: WorkspaceCapability(
        workspaceFolders: some(WorkspaceFolderCapability())),
      completionProvider: CompletionOptions(
        triggerCharacters: some(@["."]),
        resolveProvider: some(false)),
      definitionProvider: some(true),
      referencesProvider: some(true),
      executeCommandProvider: ExecuteCommandOptions(
        commands: some(@[RESTART_COMMAND])),
      documentSymbolProvider: some(true),
      codeActionProvider: some(true)))

proc initialized(ls: LanguageServer, _: JsonNode):
    Future[void] {.async.} =
  debug "Client initialized."
  let workspaceCap = ls.initializeParams.capabilities.workspace
  if workspaceCap.isSome and workspaceCap.get.configuration.get(false):
     debug "Requesting configuration from the client"
     let configurationParams = ConfigurationParams %* {"items": [{"section": "nim"}]}

     ls.workspaceConfiguration =
       ls.connection.call("workspace/configuration",
                          %configurationParams)
     ls.workspaceConfiguration.addCallback() do (futConfiguration: Future[JsonNode]):
       if futConfiguration.error.isNil:
         debug "Received the following configuration", configuration = futConfiguration.read()
  else:
    debug "Client does not support workspace/configuration"
    ls.workspaceConfiguration.complete(newJArray())

proc orCancelled[T](fut: Future[T], ls: LanguageServer, id: int): Future[T] {.async.} =
  ls.cancelFutures[id] = newFuture[void]()
  await fut or ls.cancelFutures[id]
  ls.cancelFutures.del id
  if fut.finished:
    if fut.error.isNil:
      return fut.read
    else:
      raise fut.error
  else:
    debug "Future cancelled.", id = id
    let ex = newException(Cancelled, fmt "Cancelled {id}")
    fut.fail(ex)
    debug "Future cancelled, throwing...", id = id
    raise ex

proc cancelRequest(ls: LanguageServer, params: CancelParams):
    Future[void] {.async} =
  let
    id = params.id.getInt
    cancelFuture = ls.cancelFutures.getOrDefault id

  if not cancelFuture.isNil:
    debug "Canceled", id = id
    cancelFuture.complete()

proc uriToStash(uri: string): string =
 STORAGE / (hash(uri).toHex & ".nim")

proc getNimsuggest(ls: LanguageServer, uri: string): Future[Nimsuggest] {.async.} =
  let projectFile = await ls.openFiles[uri].projectFile
  return await ls.projectFiles[projectFile].nimsuggest

proc toDiagnostic(suggest: Suggest): Diagnostic =
  with suggest:
    let endColumn = column + doc.rfind('\'') - doc.find('\'') - 2
    let node = %* {
      "uri": pathToUri(filepath) ,
      "range": {
         "start": {
            "line": line - 1,
            "character": column
         },
         "end": {
            "line": line - 1,
            "character": column + endColumn
         }
      },
      "severity": case forth:
                    of "Error": DiagnosticSeverity.Error.int
                    of "Hint": DiagnosticSeverity.Hint.int
                    of "Warning": DiagnosticSeverity.Warning.int
                    else: DiagnosticSeverity.Error.int,
      "message": doc,
      "source": "nim",
      "code": "nimsuggest chk"
    }
    return node.to(Diagnostic)

proc checkAllFiles(ls: LanguageServer, uri: string): Future[void] {.async.} =
  debug "Running diagnostics", uri = uri
  let
    nimsuggest = await ls.getNimsuggest(uri)
    diagnostics = (await nimsuggest.chk(uriToPath(uri), uriToStash(uri)))
      .filter(sug => sug.filepath != "???")
    filesWithDiags = diagnostics.map(s => s.filepath).deduplicate()

  debug "Found diagnostics", file = filesWithDiags
  for (path, diags) in groupBy(diagnostics, s => s.filepath):
    debug "Sending diagnostics", count = diags.len, path = path
    let params = PublishDiagnosticsParams %* {
      "uri": pathToUri(path),
      "diagnostics": diags.map(toDiagnostic)
    }
    ls.connection.notify("textDocument/publishDiagnostics", %params)

  # clean files with no diags
  for path in ls.filesWithDiags.filterIt(it notin filesWithDiags):
    debug "Sending zero diags", path = path
    let params = PublishDiagnosticsParams %* {
      "uri": pathToUri(path),
      "diagnostics": @[]
    }
    ls.connection.notify("textDocument/publishDiagnostics", %params)
  ls.filesWithDiags = filesWithDiags

proc progressSupported(ls: LanguageServer): bool =
  result = ls.initializeParams.capabilities.window.get(WindowCapabilities()).workDoneProgress.get(false)

proc createOrRestartNimsuggest(ls: LanguageServer, projectFile: string, uri = ""): void =
  let
    configuration = ls.getWorkspaceConfiguration().waitFor()
    nimsuggestPath = configuration.nimsuggestPath.get("nimsuggest")
    timeout = configuration.timeout.get(REQUEST_TIMEOUT)
    nimsuggestFut = createNimsuggest(projectFile, nimsuggestPath, timeout) do (ns: Nimsuggest):
      warn "Restarting the server due to requests being to slow", projectFile = projectFile
      ls.showMessage(fmt "Restarting nimsuggest for file {projectFile} due to timeout.",
                     MessageType.Warning)
      ls.createOrRestartNimsuggest(projectFile, uri)

    token = fmt "Creating nimsuggest for {projectFile}"

  if ls.projectFiles.hasKey(projectFile):
    var nimsuggestData = ls.projectFiles[projectFile]

    nimSuggestData.nimsuggest.addCallback() do (fut: Future[Nimsuggest]) -> void:
      fut.read.stop()

    nimsuggestData.nimsuggest = nimsuggestFut
  else:
    ls.projectFiles[projectFile] = (nimsuggest: nimsuggestFut,
                                    openFiles: initOrderedSet[string]())

  if ls.progressSupported:
   discard ls.connection.call("window/workDoneProgress/create",
                              %ProgressParams(token: token))

   if ls.progressSupported:
     ls.connection.notify(
       "$/progress",
       %* {
            "token": token,
            "value": {
              "kind": "begin",
              "title": fmt "Creating nimsuggest for {projectFile}"
            }
       })

     nimsuggestFut.addCallback do (fut: Future[Nimsuggest]):
       if fut.read.failed:
         let msg = fut.read.errorMessage
         ls.showMessage(fmt "Nimsuggest initialization for {projectFile} failed with: {msg}",
                        MessageType.Error)
       else:
         ls.showMessage(fmt "Nimsuggest initialized for {projectFile}",
                        MessageType.Info)
         ls.checkAllFiles(uri).traceAsyncErrors

       ls.connection.notify(
         "$/progress",
         %* {
              "token": token,
              "value": {
                "kind": "end",
              }
         })

proc didOpen(ls: LanguageServer, params: DidOpenTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  with params.textDocument:
    debug "New document opened for URI:", uri = uri
    let
      fileStash = uriToStash(uri)
      file = open(fileStash, fmWrite)
      projectFileFuture = getProjectFile(uriToPath(uri), ls)

    ls.openFiles[uri] = (
      projectFile: projectFileFuture,
      fingerTable: @[])

    let projectFile = await projectFileFuture
    debug "Document associated with the following projectFile", uri = uri, projectFile = projectFile
    if not ls.projectFiles.hasKey(projectFile):
      ls.createOrRestartNimsuggest(projectFile, uri = uri)

    ls.projectFiles[projectFile].openFiles.incl(uri)

    for line in text.splitLines:
      ls.openFiles[uri].fingerTable.add line.createUTFMapping()
      file.writeLine line
    file.close()

proc didChange(ls: LanguageServer, params: DidChangeTextDocumentParams):
    Future[void] {.async, gcsafe.} =
   with params:
     let
       uri = textDocument.uri
       path = uriToPath(uri)
       fileStash = uriToStash(uri)
       file = open(fileStash, fmWrite)

     ls.openFiles[uri].fingerTable = @[]
     for line in contentChanges[0].text.splitLines:
       ls.openFiles[uri].fingerTable.add line.createUTFMapping()
       file.writeLine line
     file.close()

     (await ls.getNimsuggest(uri)).mod(path, dirtyfile = filestash).traceAsyncErrors

proc didSave(ls: LanguageServer, params: DidSaveTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  if (await ls.getWorkspaceConfiguration()).checkOnSave.get(true):
    debug "Checking files", uri = params.textDocument.uri
    traceAsyncErrors ls.checkAllFiles(params.textDocument.uri)

proc didClose(ls: LanguageServer, params: DidCloseTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  debug "Closed the following document:", uri = params.textDocument.uri

proc toMarkedStrings(suggest: Suggest): seq[MarkedStringOption] =
  var label = suggest.qualifiedPath.join(".")
  if suggest.forth != "":
    label &= ": " & suggest.forth

  result = @[
    MarkedStringOption %* {
       "language": "nim",
       "value": label
    }
  ]

  if suggest.doc != "":
    result.add MarkedStringOption %* {
       "language": "markdown",
       "value": suggest.doc
    }

proc hover(ls: LanguageServer, params: HoverParams, id: int):
    Future[Option[Hover]] {.async} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      suggestions = await nimsuggest
       .def(uriToPath(uri),
            uriToStash(uri),
            line + 1,
            ls.getCharacter(uri, line, character))
       .orCancelled(ls, id)
    if suggestions.len == 0:
      return none[Hover]();
    else:
      return some(Hover(contents: some(%toMarkedStrings(suggestions[0]))))

proc range*(startLine, startCharacter, endLine, endCharacter: int): Range =
  return Range %* {
     "start": {
        "line": startLine,
        "character": startCharacter
     },
     "end": {
        "line": endLine,
        "character": endCharacter
     }
  }

proc toLocation(suggest: Suggest): Location =
  with suggest:
    return Location %* {
      "uri": pathToUri(filepath),
      "range": {
         "start": {
            "line": line - 1,
            "character": column
         },
         "end": {
            "line": line - 1,
            "character": column + qualifiedPath[^1].len
         }
      }
    }

proc definition(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
    Future[seq[Location]] {.async} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      suggestLocations = await nimsuggest.def(uriToPath(uri),
                                uriToStash(uri),
                                line + 1,
                                ls.getCharacter(uri, line, character))
                             .orCancelled(ls, id)
    result = suggestLocations.map(toLocation);

proc references(ls: LanguageServer, params: ReferenceParams):
    Future[seq[Location]] {.async} =
  with (params.position, params.textDocument, params.context):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      refs = await nimsuggest
      .use(uriToPath(uri),
           uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
    result = refs
      .filter(suggest => suggest.section != ideDef or includeDeclaration)
      .map(toLocation);

proc codeAction(ls: LanguageServer, params: CodeActionParams):
    Future[seq[CodeAction]] {.async} =
  return seq[CodeAction] %* [{
    "title": "Restart nimsuggest",
    "kind": "source",
    "command": {
      "title": "Restart nimsuggest",
      "command": RESTART_COMMAND,
      "arguments": @[await getProjectFile(params.textDocument.uri.uriToPath, ls)]
    }
  }]

proc executeCommand(ls: LanguageServer, params: ExecuteCommandParams):
    Future[JsonNode] {.async} =
  let projectFile = params.arguments[0].getStr
  debug "Restarting nimsuggest", projectFile = projectFile
  ls.createOrRestartNimsuggest(projectFile, projectFile.pathToUri)
  result = newJNull()

proc toCompletionItem(suggest: Suggest): CompletionItem =
  with suggest:
    return CompletionItem %* {
      "label": qualifiedPath[^1].strip(chars = {'`'}),
      "kind": nimSymToLSPKind(suggest).int,
      "documentation": doc,
      "detail": nimSymDetails(suggest)
    }

proc completion(ls: LanguageServer, params: CompletionParams, id: int):
    Future[seq[CompletionItem]] {.async} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      completions = await nimsuggest
                            .sug(uriToPath(uri),
                                 uriToStash(uri),
                                 line + 1,
                                 ls.getCharacter(uri, line, character))
                            .orCancelled(ls, id)
    return completions.map(toCompletionItem);

proc toSymbolInformation(suggest: Suggest): SymbolInformation =
  with suggest:
    return SymbolInformation %* {
      "location": toLocation(suggest),
      "kind": nimSymToLSPSymbolKind(suggest.symKind).int,
      "name": suggest.name
    }

proc documentSymbols(ls: LanguageServer, params: DocumentSymbolParams, id: int):
    Future[seq[SymbolInformation]] {.async} =
  let
    uri = params.textDocument.uri
    nimsuggest = await ls.getNimsuggest(uri)
    symbols = await nimsuggest
                      .outline(uriToPath(uri), uriToStash(uri))
                      .orCancelled(ls, id)
  return symbols.map(toSymbolInformation);

proc registerHandlers*(connection: StreamConnection) =
  let ls = LanguageServer(
    connection: connection,
    workspaceConfiguration: Future[JsonNode](),
    projectFiles: initTable[string,
                            tuple[nimsuggest: Future[Nimsuggest],
                                  openFiles: OrderedSet[string]]](),
    cancelFutures: initTable[int, Future[void]](),
    openFiles: initTable[string,
                         tuple[projectFile: Future[string],
                               fingerTable: seq[seq[tuple[u16pos, offset: int]]]]]())
  connection.register("initialize", partial(initialize, ls))
  connection.register("textDocument/completion", partial(completion, ls))
  connection.register("textDocument/definition", partial(definition, ls))
  connection.register("textDocument/documentSymbol", partial(documentSymbols, ls))
  connection.register("textDocument/hover", partial(hover, ls))
  connection.register("textDocument/references", partial(references, ls))
  connection.register("textDocument/codeAction", partial(codeAction, ls))
  connection.register("workspace/executeCommand", partial(executeCommand, ls))

  connection.registerNotification("$/cancelRequest", partial(cancelRequest, ls))
  connection.registerNotification("initialized", partial(initialized, ls))
  connection.registerNotification("textDocument/didChange", partial(didChange, ls))
  connection.registerNotification("textDocument/didOpen", partial(didOpen, ls))
  connection.registerNotification("textDocument/didSave", partial(didSave, ls))
  connection.registerNotification("textDocument/didClose", partial(didClose, ls))

when isMainModule:
  var
    pipe = createPipe(register = true, nonBlockingWrite = false)
    stdioThread: Thread[tuple[pipe: AsyncPipe, file: File]]

  createThread(stdioThread, copyFileToPipe, (pipe: pipe, file: stdin))

  let connection = StreamConnection.new(Async(fileOutput(stdout, allowAsyncOps = true)));
  registerHandlers(connection)
  waitFor connection.start(asyncPipeInput(pipe))
