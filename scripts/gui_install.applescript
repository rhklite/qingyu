-- GUI installer for 轻语 (Qingyu).
-- Shows native dialogs, then runs scripts/install.sh in Terminal so the user can
-- watch the model download / build progress. Compile with:
--   osacompile -o "Install 轻语.app" scripts/gui_install.applescript
-- Keep the resulting app in the project folder (it finds install.sh next to itself).

on run
	set mePath to POSIX path of (path to me)
	set repoRoot to do shell script "dirname " & quoted form of mePath
	set installScript to repoRoot & "/scripts/install.sh"

	try
		do shell script "test -f " & quoted form of installScript
	on error
		display alert "Installer is in the wrong place" message "Keep “Install 轻语.app” inside the qingyu project folder, next to the scripts/ directory." as critical
		return
	end try

	display dialog "Set up 轻语 (Qingyu) — on-device push-to-talk dictation for macOS.

This builds the app, installs it into /Applications, and downloads the speech model (~547 MB)." with title "轻语 Installer" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel"

	set llm to button returned of (display dialog "Add local-LLM cleanup?  (optional)

Installs Ollama + qwen2.5:3b (~1.9 GB) to tidy up filler words and punctuation. You can skip this and switch it on later from the menu bar." with title "轻语 Installer" buttons {"Skip", "Enable"} default button "Skip")
	if llm is "Enable" then
		set llmEnv to "QINGYU_LLM=1"
	else
		set llmEnv to "QINGYU_LLM=0"
	end if

	-- Run the installer in Terminal so downloads and the build show live progress.
	set cmd to llmEnv & " bash " & quoted form of installScript
	tell application "Terminal"
		activate
		do script cmd
	end tell
end run
