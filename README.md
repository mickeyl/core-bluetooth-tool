# core-bluetooth-tool

Bluetooth Low Energy command line tool for macOS.

## Features

* Scan BLE devices
* Establish a serial TTY connection to a BLE device
* Monitor BLE devices in a live table view with customizable sorting
* Interactively communicate with BLE devices directly from your terminal
* L2CAP throughput testing (server/client with reconnect and bandwidth metrics)
* (more planned, but this is v0.4)

## Quick Start

### Installation

#### [Mint](https://github.com/yonaskolb/mint)

```sh
mint install mickeyl/core-bluetooth-tool
```

#### [Homebrew](https://brew.sh)

```sh
brew tap mickeyl/formulae
brew install core-bluetooth-tool
```

### Requirements

Since this application uses Bluetooth, you need to grant Bluetooth access to your favorite terminal emulator before
running `core-bluetooth-tool`. Otherwise, the application will be halted by the OS.

### Usage

Scan all BLE devices in vicinity (**broken in macOS Monterey < 12.3, earlier and newer versions OK**):

```sh
core-bluetooth-tool scan
```

The optional argument to `scan` is a dot-separated path made of real BLE UUIDs:

```
<serviceUUID>[.<characteristicUUID>[.<descriptorUUID>]]
device.<peripheralUUID>[.<serviceUUID>[.<characteristicUUID>[.<descriptorUUID>]]]
```

All UUID components may be supplied as 16-bit, 32-bit, or 128-bit hexadecimal identifiers.

Scan all BLE devices in vicinity providing a certain service, e.g. with a UUID of `FFF0`:

```sh
core-bluetooth-tool scan fff0
```

Establish a serial bridge to the first BLE device providing a serial communication service, e.g., with a UUID of `FFF0`:

```sh
core-bluetooth-tool bridge fff0
```

Establish a serial bridge to a concrete BLE device providing a serial communication service, e.g., with a UUID of `FFF0`:

```sh
core-bluetooth-tool bridge fff0 F890A301-A464-D37C-AAFB-9374B546F7FE
```

Interactively communicate with a BLE device (like `bridge`, but connects your terminal directly for immediate I/O):

```sh
core-bluetooth-tool autobridge fff0
```

Or with a specific device:

```sh
core-bluetooth-tool autobridge fff0 F890A301-A464-D37C-AAFB-9374B546F7FE
```

The `autobridge` command sets your terminal to raw mode and provides character-by-character bidirectional communication. Press Ctrl-C to exit and restore your terminal.

Monitor BLE devices in a live updating table view:

```sh
core-bluetooth-tool monitor
```

Monitor with custom sorting (available options: `signal`, `name`, `service`, `age`, `interval`):

```sh
core-bluetooth-tool monitor --sort-by name
core-bluetooth-tool monitor -s interval
```

**Note on sorting by interval**: Sorting by beacon interval provides a particularly stable display since BLE devices advertise with fixed, predictable intervals that are part of their design specification. Unlike signal strength which fluctuates due to environmental factors, advertising intervals remain constant and create natural groupings of devices with similar timing characteristics.

### L2CAP throughput test (macOS 10.14+/iOS 11+)

Server: publish an L2CAP PSM (set `0` to auto-assign) and report drops/bandwidth (in-place status line).

```sh
LOGLEVEL=TRACE core-bluetooth-tool l2cap-server 0 --name L2Test
```

Client: scan by peripheral name, open the given PSM, and send numbered blocks containing `[seq][uint16 length][data]`. Bandwidth is printed live on the client side as well.

```sh
LOGLEVEL=TRACE core-bluetooth-tool l2cap-client <psm-from-server> "L2Test" --payload-length 200
```

Notes:
- Server and client automatically recover if the peer disconnects/reappears.
- Payload length is chosen on the client; the server parses the explicit length field and does not need prior knowledge.
- Bandwidth switches to Kbit/s for rates below 1 Mbit/s.

## Motivation

For my work on car diagnosis apps like [OBD2 Expert](https://apps.apple.com/app/obd2-experte/id1142156521), I have been writing a lot of code to communicate
with various kinds of serial OBD2 adapters. The most common technologies here are USB (`ftdi232`), WiFi, Bluetooth 3.x (`rfcomm`), and – more recently – Bluetooth Low Energy (BLE).

While (of course) I have code that interacts with such devices, it's always important to be able to _directly_ communicate with an adapter.
This is no problem with USB, WiFi, and Bluetooth 3.x communication, as we already have tools like `minicom`, `picocom`, and `ncat` to our disposal.

For Bluetooth Low Energy devices though, this has always been kind of a hassle. In contrast to Bluetooth 3.x, the serial port is provided
through a service providing one or two BLE characteristics, one readable, and one writable.
That's why I wrote the `bridge` subcommand, which opens a pseudo `tty` and allows you to use a terminal program to seamlessly interact with the device.

And while I was there, I figured I'd extend this to facilitate more tools.

## Plans

I want to extend this tool in order to handle all the common tasks typically associated with Bluetooth Low Energy devices, such as
* scanning and printing services
* scanning and printing characteristics
* scanning and printing descriptors
* trigger bonding (by reading from an encrypted characteristic)
* subscribing to a characteristic and continously printing the output
* reading and writing to/from a characteristic

### Planned: Text UI for Autobridge
A full-featured text-based user interface (TUI) is planned for the `autobridge` command to provide enhanced visualization of BLE communication. This would include:
* Scrollable communication history
* Split-pane views showing connection status and device information
* Interactive device selection
* Real-time statistics and signal strength visualization

This would build upon the current raw terminal mode to create an `ncurses`-alike interface similar to tools like `htop`.

It might also be interesting to evaluate [PureSwift/BluetoothLinux](https://github.com/PureSwift/BluetoothLinux) in order to make this tool work
on Linux.

## Contribution

Please use under the terms of the MIT license. As always, I welcome any form of contribution.
