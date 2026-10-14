# Current Setup notes

- “Changes stay in this draft until you Apply with all outputs stopped.” Editing never automatically changes the applied profile.
- “Select Direct for an ordinary picture output, or Fill + Key for a synchronized pair.” Direct uses one endpoint; a pair uses a picture and a matching key endpoint.
- “Opaque desktop: picture alpha is solid. Paired key is white while active, black on stop.” Desktop content is fully opaque; the separate key enables/disables it downstream.
- “Direct destinations send picture only.” No separate key endpoint is used.
- “Destination names and assignments belong to the selected room profile.” Side Screens, LED Wall and Confidence are editable Largo data, not fixed UI slots.
- “Draft only. 8 active playback endpoints found. Apply rechecks device support.” The count comes from device discovery; Apply validates again before saving.
- “Draft valid. 8 active endpoints. Hardware availability is checked again at start. Changes are not applied.” Validation alone does not save or start output; start checks hardware again.
- “Applied and saved. Outputs remain stopped.” Apply saves the profile without starting it.
- “Draft reverted to the last applied profile.” Revert discards unsaved edits.

New room starts empty; Duplicate room copies an existing profile. Add destination creates an unassigned Direct destination. Each destination supports rename/remove, picture device, optional key, and supported 1080p timing. The Controls tab shows only “Room profile loaded” and the actual applied profile name, or “No room profile loaded” with a Setup prompt. Load errors appear in Setup.
