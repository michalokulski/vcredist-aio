; VCRedist AIO Offline Installer
; Template for NSIS installer script

!define PRODUCT_NAME "VCRedist AIO Offline Installer"
!define PRODUCT_VERSION "{{VERSION}}"
!define PRODUCT_PUBLISHER "VCRedist AIO"
!define PRODUCT_WEB_SITE "https://github.com/michalokulski/vcredist-aio"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\VCRedistAIO"

; Compression
SetCompressor /SOLID lzma
SetCompressorDictSize 64

; Modern UI
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

; Request admin privileges
RequestExecutionLevel admin

; Installer settings
Name "${PRODUCT_NAME}"
OutFile "VC_Redist_AIO_Offline.exe"
InstallDir "$PROGRAMFILES64\VCRedist_AIO"
ShowInstDetails show

; Variables for custom parameters
Var ExtractOnly
Var PackageSelection
Var LogFile
Var SkipValidation
Var NoReboot

; Modern UI Configuration
!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "${NSISDIR}\Contrib\Graphics\Header\nsis.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${NSISDIR}\Contrib\Graphics\Wizard\nsis.bmp"

; Pages
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; Language
!insertmacro MUI_LANGUAGE "English"

; Version Information
VIProductVersion "{{VERSION}}"
VIAddVersionKey "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey "CompanyName" "${PRODUCT_PUBLISHER}"
VIAddVersionKey "FileDescription" "Offline installer for Microsoft Visual C++ Redistributables"
VIAddVersionKey "FileVersion" "{{VERSION}}"
VIAddVersionKey "ProductVersion" "{{VERSION}}"
VIAddVersionKey "LegalCopyright" "(c) 2025 VCRedist AIO"

; Function to trim quotes from parameter values
Function TrimQuotes
  Exch $R0
  Push $R1
  Push $R2
  StrCpy $R2 "$\""
  StrCpy $R1 $R0 1
  StrCmp $R1 $R2 0 +2
    StrCpy $R0 $R0 "" 1
  StrCpy $R1 $R0 1 -1
  StrCmp $R1 $R2 0 +2
    StrCpy $R0 $R0 -1
  Pop $R2
  Pop $R1
  Exch $R0
FunctionEnd

; Initialize function - Parse command line parameters
Function .onInit
  ; Initialize variables
  StrCpy $ExtractOnly "0"
  StrCpy $PackageSelection ""
  StrCpy $LogFile ""
  StrCpy $SkipValidation "0"
  StrCpy $NoReboot "0"
  
  ; Get command line parameters
  ${GetParameters} $R0
  
  ; Check for /EXTRACT parameter
  ClearErrors
  ${GetOptions} $R0 "/EXTRACT=" $R1
  ${IfNot} ${Errors}
    StrCpy $ExtractOnly "1"
    ; Remove quotes from path if present
    Push $R1
    Call TrimQuotes
    Pop $R1
    StrCpy $INSTDIR $R1
  ${EndIf}
  
  ; Check for /PACKAGES parameter
  ClearErrors
  ${GetOptions} $R0 "/PACKAGES=" $R1
  ${IfNot} ${Errors}
    ; Remove quotes from value if present
    Push $R1
    Call TrimQuotes
    Pop $R1
    StrCpy $PackageSelection $R1
  ${EndIf}
  
  ; Check for /LOGFILE parameter
  ClearErrors
  ${GetOptions} $R0 "/LOGFILE=" $R1
  ${IfNot} ${Errors}
    ; Remove quotes from path if present
    Push $R1
    Call TrimQuotes
    Pop $R1
    StrCpy $LogFile $R1
  ${EndIf}
  
  ; Check for /SKIPVALIDATION parameter
  ClearErrors
  ${GetOptions} $R0 "/SKIPVALIDATION" $R1
  ${IfNot} ${Errors}
    StrCpy $SkipValidation "1"
  ${EndIf}
  
  ; Check for /NOREBOOT parameter
  ClearErrors
  ${GetOptions} $R0 "/NOREBOOT" $R1
  ${IfNot} ${Errors}
    StrCpy $NoReboot "1"
  ${EndIf}
FunctionEnd

; Installer Section
Section "MainSection" SEC01
  SetOutPath "$INSTDIR"
  
  DetailPrint "Extracting installation files..."
  
  ; Extract installer script
  File "install.ps1"
  
  ; Extract uninstaller script
  File "uninstall.ps1"
  
  ; Create packages directory
  CreateDirectory "$INSTDIR\packages"
  SetOutPath "$INSTDIR\packages"
  
  ; Extract all packages
{{FILE_LIST}}
  
  ; Check if extract-only mode
  ${If} $ExtractOnly == "1"
    DetailPrint "Extract-only mode: Files extracted to $INSTDIR"
    DetailPrint "Skipping installation as requested"
    
    ; If running in silent mode, just quit
    ${If} ${Silent}
      Quit
    ${Else}
      ; Interactive mode - show message box
      MessageBox MB_OK "Files extracted successfully to:$\n$\n$INSTDIR$\n$\nYou can now run install.ps1 manually."
      Quit
    ${EndIf}
  ${EndIf}
  
  ; Continue with installation
  DetailPrint "Running PowerShell installation script..."
  SetOutPath "$INSTDIR"
  
  ; Build PowerShell command line arguments
  StrCpy $1 "-PackageDir \`"$INSTDIR\packages\`""
  
  ; Add log file parameter if specified
  ${If} $LogFile != ""
    StrCpy $1 "$1 -LogDir \`"$LogFile\`""
  ${Else}
    StrCpy $1 "$1 -LogDir \`"$TEMP\`""
  ${EndIf}
  
  ; Add package selection parameter if specified
  ${If} $PackageSelection != ""
    StrCpy $1 "$1 -PackageFilter \`"$PackageSelection\`""
    DetailPrint "Package filter: $PackageSelection"
  ${EndIf}
  
  ; Add skip validation flag if requested
  ${If} $SkipValidation == "1"
    StrCpy $1 "$1 -SkipValidation"
  ${EndIf}
  
  ; Add silent flag if running in silent mode
  ${If} ${Silent}
    StrCpy $1 "$1 -Silent"
  ${EndIf}
  
  ; Run PowerShell installer
  DetailPrint "Parameters: $1"
  ExecWait 'powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "$INSTDIR\install.ps1" $1' $0
  
  ; Check exit code
  DetailPrint "Installation exit code: $0"
  
  ${If} $0 == 0
    DetailPrint "Installation completed successfully"
  ${ElseIf} $0 == 1
    DetailPrint "Installation completed with warnings"
  ${ElseIf} $0 == 3010
    DetailPrint "Installation completed (reboot required)"
    ${If} $NoReboot != "1"
      SetRebootFlag true
    ${EndIf}
  ${Else}
    DetailPrint "Installation exited with code: $0"
  ${EndIf}
  
  ; Register uninstaller in Windows Apps & Features
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoRepair" 1
  
  ; Create uninstaller executable
  WriteUninstaller "$INSTDIR\uninstall.exe"
  
SectionEnd

; Uninstaller Section
Section "Uninstall"
  ; Show confirmation dialog (unless silent)
  ${IfNot} ${Silent}
    MessageBox MB_YESNO|MB_ICONQUESTION "This will run the VCRedist AIO uninstaller.$\n$\nWARNING: This will attempt to remove all Visual C++ Redistributables, which may break applications that depend on them.$\n$\nDo you want to continue?" IDYES +2
    Abort "Uninstallation cancelled by user"
  ${EndIf}
  
  ; Run uninstall script if it exists
  ${If} ${FileExists} "$INSTDIR\uninstall.ps1"
    DetailPrint "Running uninstall script..."
    
    ; Build uninstall arguments
    StrCpy $1 "-Force"
    ${If} ${Silent}
      StrCpy $1 "$1 -Silent"
    ${EndIf}
    
    ; Execute uninstall script
    ExecWait 'powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "$INSTDIR\uninstall.ps1" $1' $0
    
    DetailPrint "Uninstall script exit code: $0"
    
    ${If} $0 == 0
      DetailPrint "Uninstallation completed successfully"
    ${Else}
      DetailPrint "Uninstallation completed with warnings (exit code: $0)"
    ${EndIf}
  ${Else}
    DetailPrint "Uninstall script not found - skipping package removal"
  ${EndIf}
  
  ; Remove uninstaller registry key
  DeleteRegKey HKLM "${UNINSTALL_KEY}"
  
  ; Remove installation files
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\uninstall.ps1"
  Delete "$INSTDIR\install.ps1"
  
  ; Remove packages directory (only if empty or user confirms)
  ${If} ${FileExists} "$INSTDIR\packages\*.*"
    ${IfNot} ${Silent}
      MessageBox MB_YESNO "Remove downloaded package files?$\n$\nDirectory: $INSTDIR\packages" IDYES +2
      Goto SkipPackageRemoval
    ${EndIf}
    RMDir /r "$INSTDIR\packages"
    SkipPackageRemoval:
  ${EndIf}
  
  ; Remove installation directory (only if empty)
  RMDir "$INSTDIR"
  
  ${IfNot} ${Silent}
    MessageBox MB_OK "VCRedist AIO has been uninstalled.$\n$\nNote: Visual C++ Redistributables may still be installed on your system if the uninstall script was not run or failed."
  ${EndIf}
SectionEnd