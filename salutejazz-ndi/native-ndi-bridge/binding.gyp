{
  "variables": {
    "ndi_sdk_dir%": "<!(node -e \"console.log(process.env.NDI_SDK_DIR || '../../NDI 6 SDK')\")"
  },
  "targets": [
    {
      "target_name": "salutejazz_ndi_bridge",
      "sources": [
        "src/ndi_addon.cc",
        "src/ndi_sender.cc"
      ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")",
        "<(ndi_sdk_dir)/Include"
      ],
      "defines": [
        "NAPI_DISABLE_CPP_EXCEPTIONS"
      ],
      "cflags_cc": [ "-std=c++17", "-fexceptions" ],
      "cflags_cc!": [ "-fno-exceptions" ],
      "conditions": [
        ["OS=='win'", {
          "libraries": [ "<(ndi_sdk_dir)/Lib/x64/Processing.NDI.Lib.x64.lib" ],
          "msvs_settings": {
            "VCCLCompilerTool": {
              "ExceptionHandling": 1,
              "AdditionalOptions": [ "/std:c++17", "/EHsc" ]
            }
          },
          "copies": [
            {
              "destination": "<(PRODUCT_DIR)",
              "files": [ "<(ndi_sdk_dir)/Bin/x64/Processing.NDI.Lib.x64.dll" ]
            }
          ]
        }],
        ["OS=='mac'", {
          "libraries": [
            "-L<(ndi_sdk_dir)/lib/macOS",
            "-lndi"
          ],
          "xcode_settings": {
            "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
            "MACOSX_DEPLOYMENT_TARGET": "11.0"
          }
        }],
        ["OS=='linux'", {
          "libraries": [ "-ldl" ]
        }]
      ]
    }
  ]
}
