<img src="assets/icon.svg" width="64" height="64" alt="">

# dellmon

Command line control of a Dell U3818DW over DDC/CI: switch the input, and set
brightness, contrast and volume without touching the joystick on the back.

```
$ dellmon get
brightness 75
contrast   75
volume     8
input      dp

$ dellmon brightness 60
brightness 75 -> 60

$ dellmon volume +10
volume 8 -> 18

$ dellmon input hdmi2
input hdmi2
```

No dependencies, no helper app, no kernel extension — one self-contained Swift
binary that speaks to the monitor directly.

## Install

```sh
make install              # builds, then installs to /usr/local/bin
make install PREFIX=~/.local
```

Or just `swift build -c release` and use `.build/release/dellmon`.

Requires macOS 12+ on Apple Silicon.

## Usage

```
dellmon <feature> [value]          read a feature, or set it
dellmon get [feature ...]          read features (all four by default)
dellmon set <feature> <value>      set a feature
dellmon list                       list DDC-capable displays
dellmon caps                       print the monitor's capability string
dellmon raw get <code>             read any VCP code
dellmon raw set <code> <value>     write any VCP code
```

| Feature      | Values                                        |
| ------------ | --------------------------------------------- |
| `brightness` | `0`–`100`                                     |
| `contrast`   | `0`–`100`                                     |
| `volume`     | `0`–`100`                                     |
| `input`      | `dp`, `hdmi1`, `hdmi2`, `usbc`, or a raw code |

Numeric values can be absolute (`60`) or relative (`+10`, `-10`), and are
clamped to the range the monitor reports.

Options: `-d/--display <n|text>` to pick a display by list index or by part of
its name or serial, `-q/--quiet` for bare values suitable for scripting,
`-v/--verbose` to dump DDC packets to stderr, `-h/--help`.

Handy for hotkeys — bind `dellmon volume +5` or `dellmon input usbc` to a key
in Raycast, skhd or Karabiner.

## How it works

DDC/CI is a small command protocol that rides on the I2C lines of the display
cable. Every setting in the monitor's OSD is a numbered *VCP feature* that can
be read and written over it: `0x10` is brightness, `0x12` contrast, `0x62`
speaker volume, `0x60` input source.

Reaching that bus is the awkward part on Apple Silicon. Intel Macs exposed
`IOFramebufferI2C`, which is gone; the replacement is `IOAVService`, a private
IOKit interface. `dellmon` resolves those three functions with `dlsym` at
startup rather than linking them, so a macOS release that removes them gives a
clear error instead of failing to launch.

Finding the right bus means walking the IORegistry. A display's identity
(`DELL U3818DW`, its serial) lives on an `IOMobileFramebufferShim` entry, while
the I2C bus hangs off a `DCPAVServiceProxy` entry with `Location = External`,
in a different branch of the tree with no link between the two. A recursive
walk always passes a framebuffer's attributes before the proxy that belongs to
it, so the two are paired in traversal order — built-in panels are skipped,
since they have no DDC bus at all.

Two quirks of this monitor are worth knowing if you extend the tool:

- It echoes discrete values in both bytes of a reply, reporting DisplayPort as
  `0x0F0F` rather than `0x0F`, so discrete reads are masked to the low byte.
- After an input change it stops answering DDC for up to three seconds, and
  leaves the bus undriven — reads come back as zeroes or as an echo of the
  bytes just written. Reads are retried against a four second budget with
  capped exponential backoff, which also covers the occasional NAK on an
  otherwise idle bus. A read normally completes in about 90ms.

## Other monitors

Nothing here is specific to the U3818DW apart from the input names. Ask any
connected monitor what it supports:

```
$ dellmon caps
(prot(monitor)type(LCD)model(U3818DW)cmds(01 02 03 07 0C E3 F3)
 vcp(02 04 05 08 10 12 14(04 05 06 08 09 0B 0C) 16 18 1A 52 60(1B 0F 11 12 )
 62 AC AE B2 B6 C6 C8 C9 CC(...) D6(01 04 05) DC(00 03 05 ) ... )
 mswhql(1)asset_eep(40)mccs_ver(2.1))
```

The `vcp(...)` list is every feature the monitor implements, and a code
followed by a parenthesised list — `60(1B 0F 11 12)` — gives the discrete
values it accepts. That is where this tool's input codes come from. Anything
not wrapped in a friendly name is still reachable:

```sh
dellmon raw set 0xD6 0x04     # power mode: standby
dellmon raw get 0xDC          # preset colour mode
```

## Troubleshooting

**"no valid reply"** — the monitor ignores DDC/CI while asleep, while showing
a different input, and for a few seconds after an input change. If it persists,
check `Menu > Others > DDC/CI` is `Enable` in the OSD.

**"no external display found"** — only external displays have a DDC bus; the
built-in laptop panel is controlled through macOS instead.

**Switching to an input with nothing attached** will show "no signal", and
macOS may drop the display entirely — in which case `dellmon` can no longer
reach it and you will need the joystick on the back of the monitor to switch
back. Check what is plugged in before switching blind.
