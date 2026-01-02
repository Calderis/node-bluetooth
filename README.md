# Node Bluetooth (Zero Dependency)

A lightweight Code-only Node.js package to control Bluetooth Low Energy (BLE) devices without any external npm dependencies (like `noble` or `binding.gyp` compilation steps).

This package spawns native subprocesses to handle Bluetooth operations, ensuring high stability and compatibility with OS-level APIs.

## Features

- **Zero npm dependencies**: Uses Node.js `child_process` and native OS drivers.
- **Cross-Platform**:
  - **macOS**: Native Swift driver (no compilation needed, runs directly).
  - **Windows**: C# driver (requires compilation once).
- **Core BLE Functionality**:
  - Scan & Detect devices
  - Connect & Disconnect
  - Discover Services & Characteristics
  - Read & Write Characteristics

## Prerequisites

### macOS
- **System**: macOS 10.13 or later.
- **Requirements**: None. The package uses `/usr/bin/swift` which comes pre-installed on macOS.

### Windows
- **System**: Windows 10/11.
- **Requirements**: You must compile the C# driver once.
  1. Open a **Developer Command Prompt for Visual Studio** (or ensure `csc.exe` is in your PATH).
  2. Run the compilation command:
     ```cmd
     csc /target:exe /out:drivers/win.exe /r:"C:\Program Files (x86)\Windows Kits\10\UnionMetadata\10.0.19041.0\Windows.winmd" /r:"C:\System.Runtime.WindowsRuntime.dll" drivers/win.cs
     ```
     *Note: The path to `Windows.winmd` depends on your Windows SDK version.*

## Installation

1. Copy this package into your project or install it if it were published.
2. Run `npm install` (just for the package.json, though there are no dependencies).

## Usage Guide

### 1. Import and Start

The manager needs to spawn the native driver process before any operation.

```javascript
const bluetooth = require('./index');

// Optional: Listen for state changes
bluetooth.on('stateChange', (state) => {
    console.log(`Bluetooth State: ${state}`); // 'poweredOn', 'poweredOff', 'unauthorized'
});

// Start the driver
bluetooth.start();
```

### 2. Scanning for Devices

```javascript
bluetooth.on('device', (device) => {
    console.log(`Found device: ${device.name} (${device.uuid}) RSSI: ${device.rssi} Services: ${device.serviceUuids}`);
});

bluetooth.on('scanStart', () => console.log('Scanning started...'));
bluetooth.on('scanStop', () => console.log('Scanning stopped.'));

// Start scanning
bluetooth.scan();

// Stop scanning after 5 seconds
setTimeout(() => {
    bluetooth.stopScan();
}, 5000);
```

### 3. Connecting to a Device

```javascript
const TARGET_UUID = 'YOUR-DEVICE-UUID';

bluetooth.on('device', (device) => {
    if (device.uuid === TARGET_UUID) {
        bluetooth.stopScan(); // Recommended: stop scanning before connecting
        bluetooth.connect(device.uuid);
    }
});

bluetooth.on('connect', (device) => {
    console.log(`Connected to ${device.uuid}`);
});

bluetooth.on('disconnect', (device) => {
    console.log(`Disconnected from ${device.uuid}`);
});
```

### 4. Discovering Services & Characteristics

Once connected, you can explore the device's capabilities.

```javascript
bluetooth.on('connect', (device) => {
    // Discover all services
    bluetooth.discoverServices(device.uuid);
});

bluetooth.on('services', (res) => {
    console.log(`Services for ${res.uuid}:`, res.services);
    
    // Pick a specific service to explore, e.g., the first one
    const serviceUuid = res.services[0];
    bluetooth.discoverCharacteristics(res.uuid, serviceUuid);
});

bluetooth.on('characteristics', (res) => {
    console.log(`Characteristics for Service ${res.service}:`, res.characteristics);
});
```

### 5. Reading and Writing

You can read data (returns Hex string) or write data (String, Buffer, or Hex).

```javascript
bluetooth.on('characteristics', (res) => {
    const charUuid = res.characteristics[0];
    
    // Read a value
    bluetooth.read(res.uuid, res.service, charUuid);

    // Write a value (Example: "Hello World")
    bluetooth.write(res.uuid, res.service, charUuid, "Hello World");
    
    // Write raw bytes (Buffer)
    const buffer = Buffer.from([0x01, 0xFF, 0xA0]);
    bluetooth.write(res.uuid, res.service, charUuid, buffer);
});

bluetooth.on('read', (res) => {
    console.log(`Read from ${res.characteristic}: ${res.data} (Hex)`);
    
    // Convert Hex to String if needed
    const str = Buffer.from(res.data, 'hex').toString('utf8');
    console.log('Decoded:', str);
});

bluetooth.on('write', (res) => {
    if (res.success) {
        console.log(`Successfully wrote to ${res.characteristic}`);
    } else {
        console.error('Write failed');
    }
});
```

## API Reference

### Methods

| Method | Description |
|--------|-------------|
| `start()` | Starts the native Bluetooth driver process. |
| `stop()` | Kills the driver process. |
| `scan()` | Starts scanning for BLE peripherals. |
| `stopScan()` | Stops the scan. |
| `connect(uuid)` | Connects to a peripheral by UUID. |
| `disconnect(uuid)` | Disconnects from a peripheral. |
| `discoverServices(uuid, [filter])` | Discovers services for a connected device. |
| `discoverCharacteristics(uuid, serviceUuid, [filter])` | Discovers characteristics for a service. |
| `read(uuid, serviceUuid, charUuid)` | Reads value from a characteristic. |
| `write(uuid, serviceUuid, charUuid, data)` | Writes data to a characteristic. `data` can be String or Buffer. |

### Events

| Event | Data Packet | Description |
|-------|-------------|-------------|
| `'stateChange'` | `string` | Bluetooth adapter state (e.g., 'poweredOn'). |
| `'device'` | `{ uuid, name, rssi, serviceUuids }` | Discovered peripheral. |
| `'connect'` | `{ uuid }` | Connection established. |
| `'disconnect'` | `{ uuid }` | Connection lost/closed. |
| `'services'` | `{ uuid, services: [] }` | List of service UUIDs found. |
| `'characteristics'` | `{ uuid, service, characteristics: [] }` | List of characteristic UUIDs found. |
| `'read'` | `{ uuid, service, characteristic, data }` | Data read (hex string). |
| `'write'` | `{ uuid, service, characteristic, success }` | Write confirmation. |

## Troubleshooting

- **Permissions (macOS)**: Ensure your Terminal or IDE has permission to access Bluetooth. You may see a system popup requesting access.
- **Permissions (Windows)**: Ensure the compiled `.exe` is not blocked by antivirus software.
- **No Devices Found**: Check if your Bluetooth is on and if the device is advertising.
