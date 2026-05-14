#NoTrayIcon
#include <AutoItConstants.au3>

Opt("WinTitleMatchMode", 2)
HotKeySet("+{ESC}", "Terminate")

ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] Multimon watcher started..." & @CRLF)

While 1
    ; --- Multimon minimum resolution check / Check Resolution for Dualview ---
    If WinExists("VerifyMultimon", "Please configure this system for multimon") Then
        ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] VerifyMultimon window detected, clicking Continue..." & @CRLF)
        WinActivate("VerifyMultimon")
        WinWaitActive("VerifyMultimon", "", 2)
        If Not ControlClick("VerifyMultimon", "", "[TEXT:Continue]") Then
            ControlClick("VerifyMultimon", "", "[CLASS:Button; INSTANCE:3]")
        EndIf
        WinWaitClose("VerifyMultimon", "", 3)
    EndIf

    Sleep(200)
WEnd

Func Terminate()
    Exit
EndFunc
