# core-bluetooth-tool

A Bluetooth Low Energy Tool for macOS.

## Features

* Scan BLE devices
* Establish a serial TTY connection to a BLE device
* (more planned is planned, but this is v0.1)

## Quick Start

### Installation

#### Mint

TBD

#### Homebrew

TBD

### Usage

Scan BLE devices in vincinity:

`core-bluetooth-tool scan`

Establishing a serial bridge, e.g. to a BLE device that provides a serial communication service FFF0:

`core-bluetooth-tool bridge fff0`

## Motivation

For my work on car diagnosis apps like [OBD2 Expert](https://apps.apple.com/app/obd2-experte/id1142156521), I have been writing a lot of code to communicate
with various kinds of serial OBD2 adapters. The most common technologies here are USB (`ftdi232`), WiFi, and Bluetooth 3.x (`rfcomm`), and – more recently – Bluetooth Low Energy (BLE).

While (of course) I have code that interacts with such devices, it's always important to be able to _directly_ communicate with an adapter.
This is no problem with USB, WiFi, and Bluetooth 3.x communication, as we have tools like `minicom`, `picocom`, and `ncat` to our disposal.

For Bluetooth Low Energy devices though, this has always been kind of a hassle. In contrast to Bluetooth 3.x, there is no serial port available.
That's why I wrote the `bridge` subcommand, which opens a pseudo `tty` and allows you to use a terminal program to seamlessly interact with the device.

And while I was there, I figured I'd extend this to facilitate more tools.

## Plans

I want to extend this tool in order to handle all the common tasks typically associated with Bluetooth Low Energy devices, such as
* scanning and printing services
* scanning and printing characteristics
* scanning and printing descriptors
* trigger bonding (by reading from an encrypted characteristic)
* subscribing to a characteristic and printing the output
* reading and writing to/from a characteristic

It would also be nice to have kind of a `readline`-based REPL, where you directly interact with one device.
I could even imagine an `ncurses`-alike interface (such as `htop` is presenting) for showing the signal strength of devices in vincinity.

## Contribution

Please use under the terms of the MIT license. As always, I welcome any form of contribution.
