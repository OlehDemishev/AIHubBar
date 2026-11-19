; AI Hub Bar's additions to Tauri's NSIS installer (docs/specs/SPEC-windows.md §7): `claudepult.exe` sits next to the
; app, and its folder goes into the user's Path so `claudepult` works in any terminal; the uninstaller takes it out.
; PowerShell edits the raw registry value (Path entries like %USERPROFILE%\bin stay unexpanded, and a long Path isn't
; cut at NSIS's string limit); the folder comes in an environment variable, so quotes in it can't break the command.
; Setting and clearing a dummy user variable makes Windows tell running programs that the environment changed.

!macro AIHUBBAR_PATH SCRIPT
  System::Call 'Kernel32::SetEnvironmentVariable(t "AIHUBBAR_DIR", t "$INSTDIR")'
  nsExec::ExecToLog `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "${SCRIPT}"`
  Pop $0
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro AIHUBBAR_PATH "$$d = $$env:AIHUBBAR_DIR; $$p = (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames'); $$parts = @($$p -split ';' | Where-Object { $$_ }); if ($$parts -notcontains $$d) { New-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value (($$parts + $$d) -join ';') -PropertyType ExpandString -Force | Out-Null; [Environment]::SetEnvironmentVariable('AIHUBBAR_REFRESH', '1', 'User'); [Environment]::SetEnvironmentVariable('AIHUBBAR_REFRESH', $$null, 'User') }"
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ; Tauri's uninstaller puts back the extension's previous file class (none) and deletes its own, but leaves the empty
  ; `.claudepult` key with its backup value; it goes too, unless another program has taken the extension since.
  ReadRegStr $R0 HKCU "Software\Classes\.claudepult" ""
  StrCmp $R0 "" 0 +2
    DeleteRegKey HKCU "Software\Classes\.claudepult"
  !insertmacro AIHUBBAR_PATH "$$d = $$env:AIHUBBAR_DIR; $$p = (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames'); $$parts = @($$p -split ';' | Where-Object { $$_ -and $$_ -ne $$d }); New-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value ($$parts -join ';') -PropertyType ExpandString -Force | Out-Null; [Environment]::SetEnvironmentVariable('AIHUBBAR_REFRESH', '1', 'User'); [Environment]::SetEnvironmentVariable('AIHUBBAR_REFRESH', $$null, 'User')"
!macroend
