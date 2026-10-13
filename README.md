# Grimfall MythicPlus Timer

A lightweight and compact Mythic+ timer and progress UI for **World of Warcraft 3.3.5** on the **Grimfall** server.

The addon replaces the default Mythic+ progress display with a cleaner and more compact interface while keeping the original Grimfall Mythic+ data available in the background.

<img width="391" height="309" alt="Screenshot_45" src="https://github.com/user-attachments/assets/19c2224b-d09b-4181-a3f7-f4013de5d68b" />
<img width="401" height="326" alt="Screenshot_44" src="https://github.com/user-attachments/assets/d5f71ffb-d321-4e93-a883-34627ee2f6d8" />

## Features

* Compact Mythic+ timer
* Dungeon name, keystone level and active affixes
* Supports affix display when another party member starts the keystone
* Enemy Forces progress with percentage and progress bar
* Boss objective tracking
* Boss kill timestamps
* Completed bosses are highlighted in green
* Run result remains visible after the dungeon is completed
* Optional background panel and border
* Movable and lockable frame
* Saved frame position and panel settings
* Built-in test mode
* No external libraries required

## Installation

1. Download the latest release.

2. Extract the `GrimfallMythicPlusTimer` folder into:

   `World of Warcraft/Interface/AddOns/`

3. Make sure the directory looks like this:

   `Interface/AddOns/GrimfallMythicPlusTimer/Core.lua`

   `Interface/AddOns/GrimfallMythicPlusTimer/GrimfallMythicPlusTimer.toc`

4. Start or restart the game.

## Slash Commands

Both `/gmpt` and `/gmt` can be used as command prefixes.

* `/gmpt test` — toggle the test interface on or off
* `/gmpt panel` — toggle the background panel and border
* `/gmpt lock` — lock the timer frame in place
* `/gmpt unlock` — unlock the timer frame so it can be moved
* `/gmpt reset` — reset the timer frame to its default position
* `/gmpt hide` — hide the timer frame

Entering `/gmpt` without an argument displays the available commands in chat.

## Moving the Timer

Use:

`/gmpt unlock`

Then drag the timer by its upper area.

When you are happy with its position, use:

`/gmpt lock`

The position is saved between sessions.

## Test Mode

You can preview the addon without starting a Mythic+ dungeon:

`/gmpt test`

Run the command again to disable test mode.

## Panel

By default, the interface can be displayed without a visible background.

Use:

`/gmpt panel`

to toggle a light background with a dark border.

The selected panel state is saved between sessions and `/reload`.

## Compatibility

Designed for:

* World of Warcraft 3.3.5
* Grimfall
* Grimfall Mythic+ system

This addon relies on Grimfall-specific Mythic+ API behavior and is not intended to work with standard Wrath of the Lich King 3.3.5 servers without modification.

## Libraries

No external libraries are required.

The addon uses the standard WoW UI API together with the Mythic+ functionality provided by Grimfall.

## Author

**Frankyheal**
aka
**Frankyboya**

## Feedback and Issues

If you encounter a bug or unexpected behavior, please open an issue on GitHub or in game Frankyheal and describe:

* What happened
* What you expected to happen
* Whether the keystone belonged to you or another party member
* Any Lua error message, if available
