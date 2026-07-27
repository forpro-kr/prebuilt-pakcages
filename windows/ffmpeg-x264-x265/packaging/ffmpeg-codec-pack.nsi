Unicode true
RequestExecutionLevel user

!include "MUI2.nsh"

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

Name "RePC FFmpeg x264/x265 codec pack"
OutFile "${REPC_OUT_FILE}"
InstallDir "$LOCALAPPDATA\ForPro\RePC\codecs\ffmpeg\${REPC_ARCH}"
InstallDirRegKey HKCU "Software\ForPro\RePC\FFmpegCodecPack" "InstallDir"
BrandingText "ForPro RePC"

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${REPC_STAGE_DIR}\licenses\FFmpeg-COPYING.GPLv2.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Korean"

Section "RePC FFmpeg codec pack" SEC_CODEC_PACK
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${REPC_STAGE_DIR}\bin\${REPC_ARCH}\*"
  File "${REPC_STAGE_DIR}\manifest.json"
  File "${REPC_STAGE_DIR}\README.txt"
  File "${REPC_STAGE_DIR}\THIRD_PARTY_NOTICES.md"

  SetOutPath "$INSTDIR\licenses"
  File /r "${REPC_STAGE_DIR}\licenses\*"

  SetOutPath "$INSTDIR\sources"
  File /r "${REPC_STAGE_DIR}\sources\*"

  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\ForPro\RePC\FFmpegCodecPack" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\RePCFFmpegCodecPack" \
    "DisplayName" "RePC FFmpeg x264/x265 codec pack"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\RePCFFmpegCodecPack" \
    "DisplayVersion" "${REPC_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\RePCFFmpegCodecPack" \
    "Publisher" "ForPro"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\RePCFFmpegCodecPack" \
    "UninstallString" '"$INSTDIR\uninstall.exe"'
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\ForPro\RePC\FFmpegCodecPack"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\RePCFFmpegCodecPack"
SectionEnd
