Quick Draw Charge Tracker (Ashita v4)
=====================================

Files in this folder:
- quickdraw.lua      → The addon script
- burning_card.png   → The card image used for charges

Installation
------------
1. Copy the entire "quickdraw" folder into:
   Ashita\addons\

2. In-game type:
   /addon load quickdraw

3. Position and size it:
   /qd pos 100 200
   /qd scale 0.40

4. Optional - test sound/pulse:
   /qd test

5. (Recommended) Add to your auto-load script
   (usually scripts\default.txt):
   /addon load quickdraw

Commands
--------
/qd pos <x> <y>     Move the display
/qd scale <number>  Change size (try 0.30 to 0.55)
/qd sound           Toggle sound on/off
/qd test            Test sound + pulse animation

Notes
-----
- Position and scale are saved automatically.
- Works on Corsair main or sub job.
- Sound file must be named reload.wav (16-bit WAV recommended).
