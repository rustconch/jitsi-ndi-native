'use strict';

// Resolve native binding via node-bindings — works for both `npm install`
// (build/Release) and prebuilt locations.
const bindings = require('bindings');
const native = bindings('salutejazz_ndi_bridge');

module.exports = {
  createSender: native.createSender,
  destroySender: native.destroySender,
  sendVideo: native.sendVideo,
  sendAudio: native.sendAudio,
  FourCC: native.FourCC,
};
