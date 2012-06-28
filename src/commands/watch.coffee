'use strict'

async = require 'async'
chokidar = require 'chokidar'
sysPath = require 'path'
helpers = require '../helpers'
logger = require '../logger'
fs_utils = require '../fs_utils'

# Get paths to files that plugins include. E.g. handlebars-brunch includes
# `../vendor/handlebars-runtime.js` with path relative to plugin.
#
# plugins - Array of brunch plugins.
#
# Returns Array of Strings. 
getPluginIncludes = (plugins) ->
  plugins
    .map((plugin) -> plugin.include)
    .map(helpers.callFunctionOrPass)
    .filter((paths) -> paths?)
    .reduce(((acc, elem) -> acc.concat(helpers.ensureArray elem)), [])

# Config.files.joinTo item can be a RegExp or a function.
# The function makes universal API to them.
#
# item - RegExp or Function
#
# Returns Function.
makeUniversalChecker = (item) ->
  switch toString.call(item)
    when '[object RegExp]'
      (string) -> item.test string
    when '[object Function]'
      item
    else
      throw new Error("Config.files item #{item} is invalid.
Use RegExp or Function.")

# Can be used in `reduce` as `array.reduce(listToObj, {})`.
listToObj = (acc, elem) ->
  acc[elem[0]] = elem[1]
  acc

# Converts `config.files[...].joinTo` to one format.
# config.files[type].joinTo can be a string, a map of {str: regexp} or a map
# of {str: function}.
#
# Example output:
#
# {
#   javascripts: {'javascripts/app.js': checker},
#   templates: {'javascripts/app.js': checker2}
# }
#
# Returns Object of Object-s.
getJoinConfig = (config) ->
  types = Object.keys(config.files)
  result = types
    .map (type) ->
      config.files[type].joinTo
    .map (joinTo) ->
      if typeof joinTo is 'string'
        object = {}
        object[joinTo] = /.+/
        object
      else
        joinTo
    .map (joinTo, index) ->
      makeChecker = (generatedFilePath) ->
        [generatedFilePath, makeUniversalChecker(joinTo[generatedFilePath])]
      subConfig = Object.keys(joinTo).map(makeChecker).reduce(listToObj, {})
      [types[index], subConfig]
    .reduce(listToObj, {})
  Object.freeze(result)

isFunction = (item) -> typeof item is 'function'

propIsFunction = (prop) -> (object) -> isFunction object[prop]

generateParams = (persistent, options) ->
  params = {}
  params.minify = Boolean options.minify
  params.persistent = persistent
  if options.publicPath
    params.paths = {}
    params.paths.public = options.publicPath
  if persistent
    params.server = {}
    params.server.run = yes if options.server
    params.server.port = options.port if options.port
  params

# Filter paths that exist and watch them with `chokidar` package.
#
# config   - application config
# callback - Function that will take (error, `chokidar.FSWatcher` instance).
#
# Returns nothing.
initWatcher = (config, callback) ->
  watched = [
    config.paths.app, config.paths.test,
    config.paths.config, config.paths.packageConfig
  ].concat(config.paths.vendor, config.paths.assets)

  async.filter watched, fs_utils.exists, (watchedFiles) ->
    watcher = chokidar.watch watchedFiles,
      ignored: fs_utils.ignored,
      persistent: config.persistent
    watcher
      .on 'add', (path) ->
        logger.debug 'watcher', "File '#{path}' received event 'add'"
      .on 'change', (path) ->
        logger.debug 'watcher', "File '#{path}' received event 'change'"
      .on 'unlink', (path) ->
        logger.debug 'watcher', "File '#{path}' received event 'unlink'"
      .on('error', logger.error)
    callback null, watcher

# path   - Path to source file that can be compiled with plugin
# plugin - Brunch plugin instance.
# Returns boolean.
isCompilerFor = (path) -> (plugin) ->
  pattern = if plugin.pattern
    plugin.pattern
  else if plugin.extension
    RegExp "\\.#{plugin.extension}$"
  else
    /$.^/
  pattern.test(path)

changeFileList = (compilers, fileList, path, isHelper) ->
  compiler = compilers.filter(isCompilerFor path)[0]
  fileList.emit 'change', path, compiler, isHelper

# Consolidate all needed info and generate files.
#
# config     - application config.
# joinConfig - an Object, generated from app config by `getJoinConfig()`
# fileList   - `fs_utils.FileList` instance.
# minifiers  - Array of Object-s (brunch plugins that are treated as minifiers).
# watcher    - `chokidar.FSWatcher` instance.
# callback   - Function, that will receive an array of `fs_utils.GeneratedFile`.
# startTime  - Number, timestamp of a moment when compilation started.
#
# Returns nothing.
getCompileFn = (config, joinConfig, fileList, minifiers, watcher, callback) -> (startTime) ->
  fs_utils.write fileList, config, joinConfig, minifiers, startTime, (error, generatedFiles) ->
    return logger.error "Write failed: #{error}" if error?
    logger.info "compiled in #{Date.now() - startTime}ms"
    watcher.close() unless config.persistent
    callback generatedFiles

# Restart brunch watcher.
#
# config    - application config.
# options   - options that would be passed to new watcher.
# onCompile - callback that will be passed to new watcher.
# watcher   - `chokidar.FSWatcher` instance that has `close()` method.
# server    - instance of HTTP server that has `close()` method.
# reInstall - should brunch run `npm install` before rewatching?
#
# Returns nothing.
getReloadFn = (config, options, onCompile, watcher, server) -> (reInstall) ->
  reWatch = ->
    server?.close?()
    watcher.close()
    watch(config.persistent, options, onCompile)
  if reInstall
    helpers.install config.paths.root, reWatch
  else
    reWatch()

initialize = (options, configParams, onCompile, callback) ->
  helpers.loadPackages options, (error, packages) ->
    return logger.error error if error?
    config     = helpers.loadConfig options.configPath, configParams
    joinConfig = getJoinConfig config
    plugins    = helpers.getPlugins packages, config
    compilers  = plugins.filter(propIsFunction 'compile')
    minifiers  = plugins.filter(propIsFunction 'minify')
    callbacks  = plugins.map((plugin) -> plugin.onCompile).filter(isFunction)
    callbacks.push onCompile
    callCompileCallbacks = (generatedFiles) ->
      callbacks.forEach (callback) ->
        callback generatedFiles
    fileList   = new fs_utils.FileList config
    if config.persistent and config.server.run
      server   = helpers.startServer config

    getPluginIncludes(plugins).forEach (path) ->
      changeFileList compilers, fileList, path, yes

    initWatcher config, (error, watcher) ->
      return logger.error error if error?
      compile = getCompileFn config, joinConfig, fileList, minifiers, watcher, callCompileCallbacks
      reload = getReloadFn config, options, onCompile, watcher, server
      callback error, {
        config, watcher, server, fileList, compilers, compile, reload
      }

# Binds needed events to watcher.
#
# config    - application config.
# fileList  - `fs_utils.FileList` instance.
# compilers - array of brunch plugins that can compile source code. 
# watcher   - `chokidar.FSWatcher` instance. 
# reload    - function that will reload the whole thing.
# onChange  - callback that will be executed every time any file is changed.
#
# Returns nothing.
bindWatcherEvents = (config, fileList, compilers, watcher, reload, onChange) ->
  watcher
    .on 'add', (path) ->
      onChange()
      changeFileList compilers, fileList, path, no
    .on 'change', (path) ->
      if path is config.paths.config
        reload no
      else if path is config.paths.packageConfig
        reload yes
      else
        onChange()
        changeFileList compilers, fileList, path, no
    .on 'unlink', (path) ->
      if path is config.paths.config or path is config.paths.packageConfig
        logger.info "Detected removal of config.coffee / package.json.
Exiting."
        process.exit(0)
      else
        onChange()
        fileList.emit 'unlink', path

# persistent - Boolean: should brunch build the app only once or watch it?
# options    - Object: {configPath, minify, server, port}. Only configPath is
#              needed.
# onCompile  - Function that will be executed after every successful
#              compilation. Receives an array of `fs_utils.GeneratedFile` as 2nd
#              argument.
#
# this.config is an application config.
# this._start is a mutable timestamp that represents latest compilation
# start time. It is `null` when there are no compilations.
class BrunchWatcher
  constructor: (persistent, options, onCompile) ->
    configParams = generateParams persistent, options
    initialize options, configParams, onCompile, (error, result) =>
      return logger.error error if error?
      {config, watcher, fileList, compilers, compile, reload} = result
      bindWatcherEvents config, fileList, compilers, watcher, reload, @_startCompilation
      fileList.on 'ready', => compile @_endCompilation()
      @config = config

  _startCompilation: =>
    @_start ?= Date.now()

  _endCompilation: =>
    start = @_start
    @_start = null
    start

module.exports = watch = (persistent, options, callback = (->)) ->
  new BrunchWatcher(persistent, options, callback)
