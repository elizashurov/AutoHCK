#NoTrayIcon
#include <AutoItConstants.au3>

Opt("WinTitleMatchMode", 2)
HotKeySet("+{ESC}", "Terminate")

Global $hspDone = False
Global $ignoredCmds = "|"

ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] HSP Watcher Started..." & @CRLF)

While 1
    If Not $hspDone And WinExists("C:\Windows\SYSTEM32\cmd.exe") Then
        Local $hWnd = WinGetHandle("C:\Windows\SYSTEM32\cmd.exe")

        If Not StringInStr($ignoredCmds, "|" & $hWnd & "|") Then
            WinActivate($hWnd)
            WinWaitActive($hWnd, "", 2)

            Local $bakClip = ClipGet()
            ClipPut("")

            Send("^a")
            Sleep(100)
            Send("{ENTER}")
            Sleep(200)

            Local $winText = ClipGet()
            ClipPut($bakClip)

            If StringInStr($winText, "Hardware-enforced") Then
                ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] Confirmed HSP test window, sending Y..." & @CRLF)
                Send("{ESC}")
                Sleep(100)
                Send("Y")
                Sleep(200)
                Send("{ENTER}")
                $hspDone = True
                Sleep(5000)
            Else
                Send("{ESC}")
                $ignoredCmds &= $hWnd & "|"
            EndIf
        EndIf
    EndIf

    Sleep(200)
WEnd

Func Terminate()
    Exit
EndFunc
