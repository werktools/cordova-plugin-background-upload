var exec = require('cordova/exec')

var FileTransferManager = function (options, callback) {
  this.options = options
  if (!this.options.parallelUploadsLimit) {
    this.options.parallelUploadsLimit = 1
  }

  if (typeof callback !== 'function') {
    throw new Error('event handler must be a function')
  }

  this.callback = callback
  exec(this.callback, null, 'FileTransferBackground', 'initManager', [this.options])
}

FileTransferManager.prototype.startUpload = function (payload) {
  if (!payload) {
    return this.callback({ state: 'FAILED', error: 'Upload Settings object is missing or has invalid arguments' })
  }

  if (!payload.id) {
    return this.callback({ state: 'FAILED', error: 'Upload ID is required' })
  }

  if (!payload.serverUrl) {
    return this.callback({ id: payload.id, state: 'FAILED', error: 'Server URL is required' })
  }

  if (payload.serverUrl.trim() === '') {
    return this.callback({ id: payload.id, state: 'FAILED', error: 'Invalid server URL' })
  }

  if (!payload.filePath) {
    return this.callback({ id: payload.id, state: 'FAILED', error: 'filePath is required' })
  }

  // Since we support PUT now, not having a fileKey is our indication that we want a PUT request.
  // if (!payload.fileKey) {
  //  payload.fileKey = 'file'
  // }

  if (!payload.requestMethod) {
    payload.requestMethod = 'POST'
  }

  payload.notificationTitle = payload.notificationTitle || 'Uploading files'

  if (!payload.headers) {
    payload.headers = {}
  }

  if (!payload.parameters) {
    payload.parameters = {}
  }

  var self = this;
  // For Android, the uploader wants one of two things, either a content:// URL or a
  // "legacy" path, which some content generators (i.e. camera) will still provide.
  // If we have a content URI or a 'legacy android path', pass those in without
  var urlScheme = payload.filePath.split("://")[0];

  exec(self.callback, null, 'FileTransferBackground', 'startUpload', [payload]);
  // if (urlScheme === "file" && payload.filePath.startsWith('file:///storage/emulated/0/')) {
  //   // If we have a "file://" prefix and this is an Android image, then just remove it and pass it through.
  //   payload.filePath = payload.filePath.replace(/^file:\/\//, '');
  //   exec(self.callback, null, 'FileTransferBackground', 'startUpload', [payload])
  // } else if (urlScheme === "content") {
  //   // Don't do anything. The plugin can natively handle content://
  //   exec(self.callback, null, 'FileTransferBackground', 'startUpload', [payload])
  // } else {
  //   // ios
  //   window.resolveLocalFileSystemURL(payload.filePath, function (entry) {
  //     payload.filePath = new URL(entry.toURL()).pathname.replace(/^\/local-filesystem/, '')
  //     exec(self.callback, null, 'FileTransferBackground', 'startUpload', [payload])
  //   }, function () {
  //     self.callback({ id: payload.id, state: 'FAILED', error: 'File not found: ' + payload.filePath })
  //   })
  // }
}

FileTransferManager.prototype.removeUpload = function (id, successCb, errorCb) {
  if (!id) {
    if (errorCb) {
      errorCb({ error: 'Upload ID is required' })
    }
  } else {
    exec(successCb, errorCb, 'FileTransferBackground', 'removeUpload', [id])
  }
}

FileTransferManager.prototype.acknowledgeEvent = function (id, successCb, errorCb) {
  if (!id) {
    if (errorCb) {
      errorCb({ error: 'Event ID is required' })
    }
  } else {
    exec(successCb, errorCb, 'FileTransferBackground', 'acknowledgeEvent', [id])
  }
}

FileTransferManager.prototype.destroy = function (successCb, errorCb) {
  this.callback = null
  exec(successCb, errorCb, 'FileTransferBackground', 'destroy', [])
}

module.exports = {
  init: function (options, cb) {
    return new FileTransferManager(options || {}, cb)
  },
  FileTransferManager: FileTransferManager
}
