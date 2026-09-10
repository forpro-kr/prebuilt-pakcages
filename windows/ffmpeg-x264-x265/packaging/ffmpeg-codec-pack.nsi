Unicode true
RequestExecutionLevel admin
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!ifndef REPC_ARCH
  !error "REPC_ARCH is required"
!endif
!ifndef REPC_VERSION
  !error "REPC_VERSION is required"
!endif
!ifndef REPC_STAGE_DIR
  !error "REPC_STAGE_DIR is required"
!endif
!ifndef REPC_OUT_FILE
  !error "REPC_OUT_FILE is required"
!endif
!define PACK_KEY "Software\ForPro\RePC\FFmpegCodecPack\${REPC_ARCH}"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\RePCFFmpegCodecPack-${REPC_ARCH}-${REPC_VERSION}"
!define PACK_DIR "$PROGRAMFILES64\ForPro\RePC\codecs\ffmpeg\${REPC_ARCH}\${REPC_VERSION}"
Name "forpro-remote FFmpeg 코덱 팩 (${REPC_ARCH})"
OutFile "${REPC_OUT_FILE}"
InstallDir "${PACK_DIR}"
BrandingText "forpro-remote"
SetCompressor /SOLID lzma
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${REPC_STAGE_DIR}\licenses\FFmpeg-COPYING.GPLv2.txt"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Korean"
!insertmacro MUI_LANGUAGE "English"
Function .onInit
  !if "${REPC_ARCH}" == "arm64"
    ${IfNot} ${IsNativeARM64}
      SetErrorLevel 1633
      Abort "Windows ARM64 코덱 팩입니다."
    ${EndIf}
  !else
    ${IfNot} ${IsNativeAMD64}
      SetErrorLevel 1633
      Abort "Windows x64 코덱 팩입니다."
    ${EndIf}
  !endif
  SetRegView 64
  SetShellVarContext all
  StrCpy $INSTDIR "${PACK_DIR}"
  ; Never overwrite a version that another host process may still be using.
  IfFileExists "$INSTDIR\manifest.json" 0 new_version
    ReadRegStr $0 HKLM "${PACK_KEY}" "InstallDir"
    ${If} $0 == $INSTDIR
      SetErrorLevel 0
      Quit
    ${EndIf}
    SetErrorLevel 1638
    Abort "동일 버전이 이미 있습니다. 해당 버전을 제거한 후 다시 설치하세요."
  new_version:
FunctionEnd
Section "FFmpeg 하드웨어 및 소프트웨어 인코더" SEC_CODEC_PACK
  SetOutPath "$INSTDIR"
  SetOverwrite off
  ClearErrors
  File /r "${REPC_STAGE_DIR}\bin\${REPC_ARCH}\*"
  File "${REPC_STAGE_DIR}\README.txt"
  File "${REPC_STAGE_DIR}\THIRD_PARTY_NOTICES.md"
  SetOutPath "$INSTDIR\licenses"
  File /r "${REPC_STAGE_DIR}\licenses\*"
  SetOutPath "$INSTDIR\sources"
  File /r "${REPC_STAGE_DIR}\sources\*"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  IfErrors failed
  SetOutPath "$INSTDIR"
  File "${REPC_STAGE_DIR}\manifest.json"
  IfErrors failed
  ; Switch only after successful extraction; running processes keep old DLLs.
  WriteRegStr HKLM "${PACK_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${PACK_KEY}" "Version" "${REPC_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayName" "forpro-remote FFmpeg (${REPC_ARCH}) ${REPC_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${REPC_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "Publisher" "ForPro"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoRepair" 1
  IfErrors failed
  SetErrorLevel 0
  Goto done
  failed:
    SetErrorLevel 1603
    Abort "설치에 실패했습니다. RePC를 종료하고 다시 시도하세요."
  done:
SectionEnd
Function un.onInit
  SetRegView 64
  SetShellVarContext all
  ${If} $INSTDIR != "${PACK_DIR}"
    SetErrorLevel 1603
    Abort
  ${EndIf}
FunctionEnd
Section "Uninstall"
  ; Remove only this exact version, never the app or another architecture.
  ReadRegStr $0 HKLM "${PACK_KEY}" "InstallDir"
  ${If} $0 == $INSTDIR
    DeleteRegKey HKLM "${PACK_KEY}"
  ${EndIf}
  DeleteRegKey HKLM "${UNINSTALL_KEY}"
  RMDir /r "$INSTDIR"
  IfErrors 0 +2
    SetErrorLevel 1603
SectionEnd
