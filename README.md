# PallyPower Kronos

A dual-client build of PallyPower for the Kronos private server: one addon
folder that runs on both the 1.12 vanilla client and the 1.14.x Classic Era
client played through JimsProxy, with every paladin on the same assignment
protocol regardless of client.

Maintained by **Mirasu** of Kronos. Based on PallyPower Classic v1.4.4 by
Aznamir, Dyaxler and Es; the original licence file is kept in the addon
folder.

## How the two builds fit together

- The 1.14 client reads `PallyPower_Vanilla.toc` and loads the stock
  v1.4.4-classic code with Kronos patches.
- The 1.12 client reads `PallyPower.toc` (Interface 11200) and loads
  `Classic112\PallyPower112.lua`, a self-contained Lua 5.0 rewrite with the
  same bar, flyout, assignment grid, per-player normal blessings and pet
  class.
- Both speak the PLPWR protocol. The 1.12 build sends the original 1.12
  ids on PLPWR, which the proxy translates for 1.14 clients; messages that
  have no 1.12 equivalent (per-player blessings, pet assignments, aura info,
  the status combo) travel untranslated on a second prefix, PLPWRX.
- Addon whispers do not exist in the 1.12 network protocol, so the 1.14
  build always broadcasts to the group.

## Install

Drop the `PallyPower` folder into `Interface\AddOns` of either client. On
the 1.12 client, restart the game after adding or updating the folder.

## Commands

`/pp` opens the assignment grid on both clients. The 1.12 build also has
`/pp bar`, `/pp report`, `/pp clear`, `/pp free`, `/pp lock`, `/pp solo`,
`/pp sync` and `/pp scale <n>`.

## Kronos changes to the 1.14 build

- Broadcast instead of whisper, second prefix for untranslatable messages,
  pet assignment re-sent after every SELF.
- "None" is sent as -1 on the wire and accepted on receipt, since the old
  id 0 means Wisdom.
- SELF no longer wipes the pet slot, normal assignments or status of the
  sender, and status that arrives ahead of a SELF is applied after it.
- Class buttons keep their in-combat rotation across repeated clicks.
- Cooldown status refreshes instead of sticking at "Ready".

## Development

`dev/harness.lua` runs the 1.12 build under desktop Lua with a mock client,
covering login and reload, events, clicks, and the comm protocol:

```
lua dev/harness.lua PallyPower/Classic112/PallyPower112.lua
lua dev/harness.lua PallyPower/Classic112/PallyPower112.lua pew
```

The 1.12 file must stay Lua 5.0: no `#` or `%` operators, no `select`,
`gmatch` or varargs, and at most 32 upvalues per function, which is why all
of its state lives on one table.
