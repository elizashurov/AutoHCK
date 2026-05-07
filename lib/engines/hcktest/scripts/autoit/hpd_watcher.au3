#NoTrayIcon
#include <AutoItConstants.au3>

Opt("WinTitleMatchMode", 2)
HotKeySet("+{ESC}", "Terminate")

ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] HPD watcher started..." & @CRLF)

While 1
    ; --- WDDM HPD Notification Test (Manual) ---
    If WinExists("HPDClientU", "Waiting for HPD removal") Then
        ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] HPD window detected, clicking Skip..." & @CRLF)
        WinActivate("HPDClientU")
        WinWaitActive("HPDClientU", "", 2)
        ControlClick("HPDClientU", "", "[TEXT:Skip]")
        WinWaitClose("HPDClientU", "", 3)
    EndIf

    Sleep(200)
WEnd

Func Terminate()
    Exit
EndFunc
