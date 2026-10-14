# Current hardware-first Setup notes

The Setup page has one sidebar group, **Outputs**. Rows use detected SDK output names, not saved Side/LED/Confidence destination names. Selecting an output shows Direct / Fill + Key and supported timing controls on the right.

- “Draft changes • Apply with outputs stopped”: edits are drafts until Apply; no output is started by saving.
- “Direct”: one picture output, without a separate key.
- “Fill + Key”: the selected output is Fill; choose Key from eligible unused outputs on the same synchronization-capable card. The Timing menu contains only common modes supported by both outputs and the app.
- “Key source for [fill output name]”: this output belongs to the displayed fill. Its sidebar row is disabled for independent editing. Set its fill to Direct or remove that assignment to release it in the draft.
- “Not configured”: detected output not currently assigned in the profile. Configure output adds it; Remove assignment releases its picture/key assignment.
- “Fill: … ↳ Key: …”: shows the pairing relationship explicitly.
- “Rescan”: rereads cards, outputs and modes without changing saved assignments or hardware settings.
- “Draft valid. Not applied.”: validation passed, but the changes are still drafts.
- “Applied and saved. Outputs remain stopped.”: profile saved without starting playback.
- “Draft reverted to the last applied profile.”: unsaved edits discarded.

New room starts without assignments; Duplicate preserves existing assignments in a new room draft. Controls remains “Room profile loaded” with the applied name. The opaque-desktop policy is unchanged: solid picture alpha, white active key, black on stop. Hardware-supported modes outside the app's progressive1920×1080 pipeline are inventoried but are not selectable for playback.
