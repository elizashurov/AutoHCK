#NoTrayIcon
#include <AutoItConstants.au3>

Opt("WinTitleMatchMode", 2)
HotKeySet("+{ESC}", "Terminate")

ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] EDID watcher started..." & @CRLF)

While 1
    ; --- Type A: Timing inquiry (steps 1 and 3) ---
    If WinExists("CCD EDID Test : Detailed Timing Block", "Is this the native timing") Then
        ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] EDID Timing window detected, clicking Yes..." & @CRLF)
        WinActivate("CCD EDID Test : Detailed Timing Block")
        WinWaitActive("CCD EDID Test : Detailed Timing Block", "", 2)
        ControlClick("CCD EDID Test : Detailed Timing Block", "", "[CLASS:Button; TEXT:Yes]")
        If Not WinWaitClose("CCD EDID Test : Detailed Timing Block", "", 2) Then
            Send("{ENTER}")
            WinWaitClose("CCD EDID Test : Detailed Timing Block", "", 3)
        EndIf
        Sleep(500)
    EndIf

    ; --- Type B: Screen Size inquiry (steps 2 and 4) ---
    If WinExists("CCD EDID Test : Screen Size", "Is the screen size") Then
        ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] EDID Screen Size window detected, clicking Yes..." & @CRLF)
        WinActivate("CCD EDID Test : Screen Size")
        WinWaitActive("CCD EDID Test : Screen Size", "", 2)
        ControlClick("CCD EDID Test : Screen Size", "", "[CLASS:Button; TEXT:Yes]")
        If Not WinWaitClose("CCD EDID Test : Screen Size", "", 2) Then
            Send("{ENTER}")
            WinWaitClose("CCD EDID Test : Screen Size", "", 3)
        EndIf
        Sleep(500)
    EndIf

    ; --- Type C: Final Result (step 5) ---
    If WinExists("CCDEdid", "Test Passed") Then
        ConsoleWrite("[" & @HOUR & ":" & @MIN & ":" & @SEC & "] EDID final window detected, clicking Exit..." & @CRLF)
        WinActivate("CCDEdid")
        WinWaitActive("CCDEdid", "", 2)
        ControlClick("CCDEdid", "", "[CLASS:Button; TEXT:Exit]")
        If Not WinWaitClose("CCDEdid", "", 2) Then
            Send("{ENTER}")
            WinWaitClose("CCDEdid", "", 3)
        EndIf
        Sleep(3000)
    EndIf

    Sleep(200)
WEnd

Func Terminate()
    Exit
EndFunc
