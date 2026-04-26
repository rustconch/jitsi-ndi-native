$ErrorActionPreference = "Stop"

Set-Location "D:\MEDIA\Desktop\jitsi-ndi-native"

if (!(Test-Path "D:\vcpkg\vcpkg.exe")) {
    if (!(Test-Path "D:\vcpkg")) {
        git clone https://github.com/microsoft/vcpkg.git D:\vcpkg
    }
    & D:\vcpkg\bootstrap-vcpkg.bat
}

& D:\vcpkg\vcpkg.exe install openssl:x64-windows

Remove-Item -Recurse -Force .\build-ndi -ErrorAction SilentlyContinue

cmake -S . -B build-ndi -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_TOOLCHAIN_FILE="D:/vcpkg/scripts/buildsystems/vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows `
  -DJNN_NDI_SDK_DIR="C:\Program Files\NDI\NDI 6 SDK"

cmake --build build-ndi --config Release

$dst = ".\build-ndi\Release"
Copy-Item "D:\vcpkg\installed\x64-windows\bin\libcrypto-3-x64.dll" $dst -Force -ErrorAction SilentlyContinue
Copy-Item "D:\vcpkg\installed\x64-windows\bin\libssl-3-x64.dll" $dst -Force -ErrorAction SilentlyContinue

Write-Host "Built: $dst\jitsi-ndi-native.exe"
