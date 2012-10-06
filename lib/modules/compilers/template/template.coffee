path = require 'path'
fs =   require 'fs'

wrench = require 'wrench'
_ =      require 'lodash'

requireRegister =  require '../../require/register'
fileUtils =        require '../../../util/file'
logger =           require '../../../util/logger'

module.exports = class AbstractTemplateCompiler

  constructor: (config) ->
    if @clientLibrary?
      @mimosaClientLibraryPath = path.join __dirname, "client", "#{@clientLibrary}.js"
      jsDir = path.join config.watch.compiledDir, config.watch.javascriptDir
      @clientPath = path.join jsDir, 'vendor', "#{@clientLibrary}.js"

  lifecycleRegistration: (config, register) ->
    register ['startupExtension'], 'init',       @_gatherFiles,            [@extensions[0]]
    register ['startupExtension'], 'beforeRead', @_templateNeedsCompiling, [@extensions[0]]
    register ['startupExtension'], 'compile',    @_compile,                [@extensions[0]]

    register ['add','update','remove'], 'init',       @_gatherFiles,            [@extensions...]
    register ['add','update','remove'], 'beforeRead', @_templateNeedsCompiling, [@extensions...]
    register ['add','update','remove'], 'compile',    @_compile,                [@extensions...]

    unless config.virgin
      register ['startupExtension'],      'afterCompile', @_merge, [@extensions[0]]
      register ['add','update','remove'], 'afterCompile', @_merge, [@extensions...]

      register ['remove'],           'beforeRead',   @_testForRemoveClientLibrary, [@extensions...]
      register ['add','update'],     'afterCompile', @_readInClientLibrary,        [@extensions...]
      register ['startupExtension'], 'afterCompile', @_readInClientLibrary,        [@extensions[0]]

  _gatherFiles: (config, options, next) =>
    allFiles = wrench.readdirSyncRecursive(config.watch.sourceDir)
      .map (file) => path.join(config.watch.sourceDir, file)

    fileNames = []
    for file in allFiles
      extension = path.extname(file).substring(1)
      fileNames.push(file) if _.any(@extensions, (ext) -> ext is extension)

    if fileNames.length is 0
      options.files = []
    else
      @_testForSameTemplateName(fileNames) unless fileNames.length is 1
      options.files = fileNames.map (file) ->
        inputFileName:file
        inputFileText:null
        outputFileText:null

    next()

  _compile: (config, options, next) =>
    return next() if options.files?.length is 0

    i = 0
    newFiles = []
    options.files.forEach (file) =>
      logger.debug "Compiling HTML template [[ #{file.inputFileName} ]]"
      templateName = @__generateTemplateName(file.inputFileName)
      @compile file, templateName, (err, result) =>
        if err
          logger.error "Template [[ #{file.inputFileName} ]] failed to compile. Reason: #{err}"
        else
          result = "templates['#{templateName}'] = #{result}\n" unless @handlesNamespacing
          file.outputFileText = result
          newFiles.push file

        if ++i is options.files.length
          # end of the road for virgin, log it
          if config.virgin and options.files.length is newFiles.length
            logger.success "All templates compiled successfully.", options

          options.files = newFiles
          next()

  _merge: (config, options, next) =>
    return next() unless options.files?.length > 0

    mergedText = @filePrefix()
    options.files.forEach (file) =>
      mergedText += @templatePreamble file.inputFileName
      mergedText += file.outputFileText

    mergedText += @fileSuffix()

    options.files.push
      outputFileText: mergedText
      outputFileName: options.destinationFile()

    next()

  __generateTemplateName: (fileName) ->
    path.basename fileName, path.extname(fileName)

  _testForRemoveClientLibrary: (config, options, next) =>
    if options.files?.length is 0
      logger.debug "No template files left, removing [[ #{@clientPath} ]]"
      @removeClientLibrary(next)
    else
      next()

  removeClientLibrary: (cb) ->
    if @clientPath?
      fs.exists @clientPath, (exists) ->
        if exists
          logger.debug "Removing client library [[ #{@clientPath} ]]"
          fs.unlinkSync @clientPath, (err) -> cb()
        else
          cb()
    else
      cb()

  _testForSameTemplateName: (fileNames) ->
    templateHash = {}
    fileNames.forEach (fileName) ->
      templateName = path.basename(fileName, path.extname(fileName))
      if templateHash[templateName]?
        logger.error "Files [[ #{templateHash[templateName]} ]] and [[ #{fileName} ]] result in templates of the same name " +
                     "being created.  You will want to change the name for one of them or they will collide."
      else
        templateHash[templateName] = fileName

  _templateNeedsCompiling: (config, options, next) =>
    return next(false) if options.files?.length is 0

    fileNames = _.pluck(options.files, 'inputFileName')
    numFiles = fileNames.length

    i = 0
    processFile = =>
      if i < numFiles
        fileUtils.isFirstFileNewer fileNames[i++], options.destinationFile(), cb
      else
        # no need to compile, remove files, but let continue
        options.files = []
        next()

    cb = (isNewer) =>
      if isNewer then next() else processFile()

    processFile()

  _readInClientLibrary: (config, options, next) =>
    if !@clientPath? or fs.existsSync @clientPath
      logger.debug "Not going to write template client library"
      return next()

    logger.debug "Adding template client library [[ #{@mimosaClientLibraryPath} ]] to list of files to write"

    fs.readFile @mimosaClientLibraryPath, "ascii", (err, data) =>
      if err
        logger.error("Cannot read client library [[ #{@mimosaClientLibraryPath} ]]")
        return next()

      options.files.push
        outputFileName: @clientPath
        outputFileText: data

      next()

  libraryPath: ->
    libPath = "vendor/#{@clientLibrary}"
    requireRegister.aliasForPath(libPath) ? libPath

  templatePreamble: (fileName) ->
    """
    \n//
    // Source file: [#{fileName}]
    // Template name: [#{@__generateTemplateName(fileName)}]
    //\n
    """