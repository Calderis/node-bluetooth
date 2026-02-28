const { spawn } = require('child_process');
const path = require('path');
const EventEmitter = require('events');
const os = require('os');

class BluetoothManager extends EventEmitter {
    constructor() {
        super();
        this.process = null;
        this.buffer = '';
        this.isStarted = false;

        // Bind methods
        this.start = this.start.bind(this);
        this.stop = this.stop.bind(this);
        this.scan = this.scan.bind(this);
        this.connect = this.connect.bind(this);
        this.disconnect = this.disconnect.bind(this);
    }

    start() {
        if (this.isStarted) return;

        let cmd, args;
        const platform = os.platform();

        if (platform === 'darwin') {
            // macOS: Check for pre-compiled binary first, fallback to Swift
            const fs = require('fs');
            let compiledPath = path.join(__dirname, 'drivers', 'mac');
            // When packaged with Electron (asar), binaries must be in app.asar.unpacked
            if (compiledPath.includes('app.asar' + path.sep)) {
                compiledPath = compiledPath.replace('app.asar' + path.sep, 'app.asar.unpacked' + path.sep);
            }

            if (fs.existsSync(compiledPath)) {
                // Use pre-compiled universal binary (works without Swift installed)
                cmd = compiledPath;
                args = [];
            } else if (fs.existsSync('/usr/bin/swift')) {
                // Fallback: Run Swift interpreter (requires Xcode/Swift)
                console.warn('Using Swift interpreter. For better performance, run: npm run compile:mac');
                cmd = '/usr/bin/swift';
                args = [path.join(__dirname, 'drivers', 'mac.swift')];
            } else {
                console.error('macOS Bluetooth driver not available.');
                console.error('Please run "npm run compile:mac" on a Mac with Xcode installed.');
                return;
            }
        } else if (platform === 'win32') {
            const fs = require('fs');
            // When packaged with Electron (asar), binaries must be in app.asar.unpacked
            let exePath = path.join(__dirname, 'drivers', 'win.exe');
            if (exePath.includes('app.asar' + path.sep)) {
                exePath = exePath.replace('app.asar' + path.sep, 'app.asar.unpacked' + path.sep);
            }
            if (fs.existsSync(exePath)) {
                cmd = exePath;
                args = [];
            } else {
                console.warn("Windows driver not found. Please run 'npm run compile:win' on your Windows machine to compile drivers/win.cs");
                if (__dirname.includes('app.asar')) {
                    console.warn("Electron detected: add asarUnpack in your electron-builder config:");
                    console.warn('  "asarUnpack": ["**/node_modules/@calderis/node-bluetooth/drivers/**"]');
                }
                return;
            }
        } else {
            throw new Error(`Platform ${platform} not supported`);
        }

        this.buffer = '';
        const spawnOptions = { stdio: ['pipe', 'pipe', 'pipe'] };
        if (platform === 'win32') spawnOptions.windowsHide = true;

        try {
            this.process = spawn(cmd, args, spawnOptions);
        } catch (err) {
            console.error('Failed to start Bluetooth driver:', err);
            return;
        }

        // Attach error handler immediately — if exec fails (pid undefined), Node.js
        // emits 'error' asynchronously. Without a listener it becomes an uncaught
        // exception that crashes the process.
        this.process.on('error', (err) => {
            console.error('Bluetooth driver process error:', err.code, err.message);
            this.process = null;
            this.isStarted = false;
            this.emit('error', err);
        });

        if (!this.process.stdout || !this.process.stderr) {
            console.error('Bluetooth driver: stdio streams unavailable (pid:', this.process.pid, '). Binary may have failed to exec.');
            // Don't kill — let the pending 'error' event fire and clean up.
            this.process = null;
            return;
        }

        this.isStarted = true;

        this.process.stdout.on('data', (data) => {
            this.handleData(data);
        });

        this.process.stderr.on('data', (data) => {
            console.error(`[BT Driver Error]: ${data}`);
        });

        this.process.on('close', () => {
            this.process = null;
            this.isStarted = false;
        });
    }

    stop() {
        return new Promise((resolve) => {
            if (!this.process) return resolve();

            this.process.once('close', () => {
                this.process = null;
                this.isStarted = false;
                resolve();
            });

            // Close stdin to signal EOF — the driver will disconnect all BLE devices
            // then exit cleanly (Windows keeps devices connected until Dispose() is called).
            // Fallback: force-kill after 2 s if the driver doesn't exit on its own.
            if (this.process.stdin) {
                this.process.stdin.end();
            }
            const fallback = setTimeout(() => {
                if (this.process) this.process.kill();
            }, 2000);
            this.process.once('close', () => clearTimeout(fallback));
        });
    }

    handleData(data) {
        this.buffer += data.toString();
        // Handle both Unix (\n) and Windows (\r\n) line endings
        const lines = this.buffer.split(/\r?\n/);
        this.buffer = lines.pop(); // Keep partial line

        for (const line of lines) {
            if (!line.trim()) continue;
            try {
                const msg = JSON.parse(line);
                this.handleMessage(msg);
            } catch (e) {
                console.error('Failed to parse driver message:', line, e);
            }
        }
    }

    handleMessage(msg) {
        // Events: "onConnect" (we emit 'connect'), "onDisconnect", "onStartScanning", "onStopScanning", "onStateChange"
        switch (msg.event) {
            case 'device':
                this.emit('device', msg.data);
                break;
            case 'connected':
                this.emit('connect', msg.data); // { uuid: ... }
                break;
            case 'disconnected':
                this.emit('disconnect', msg.data); // { uuid: ... }
                break;
            case 'stateChange':
                this.emit('stateChange', msg.data); // 'poweredOn', 'poweredOff', etc.
                break;
            case 'scanStart':
                this.emit('startScanning');
                break;
            case 'scanStop':
                this.emit('stopScanning');
                break;
            case 'services':
                this.emit('services', msg.data); // { uuid: deviceUuid, services: [] }
                break;
            case 'characteristics':
                this.emit('characteristics', msg.data); // { uuid: deviceUuid, service: serviceUuid, characteristics: [] }
                break;
            case 'read':
                this.emit('read', msg.data); // { uuid, service, characteristic, data }
                break;
            case 'write':
                this.emit('write', msg.data); // { uuid, service, characteristic }
                break;
            default:
        }
    }

    sendCommand(cmd, data = {}) {
        if (!this.process) {
            throw new Error('Bluetooth driver not started');
        }
        const payload = JSON.stringify({ command: cmd, ...data }) + '\n';
        this.process.stdin.write(payload);
    }

    scan() {
        this.sendCommand('scan');
    }

    stopScan() {
        this.sendCommand('stopScan');
    }

    discoverServices(uuid, services = []) {
        this.sendCommand('discoverServices', { uuid, services });
    }

    discoverCharacteristics(uuid, serviceId, characteristics = []) {
        this.sendCommand('discoverCharacteristics', { uuid, service: serviceId, characteristics });
    }

    read(uuid, serviceId, characteristicId) {
        this.sendCommand('read', { uuid, service: serviceId, characteristic: characteristicId });
    }

    subscribe(uuid, serviceId, characteristicId, enable = true) {
        this.sendCommand('subscribe', { uuid, service: serviceId, characteristic: characteristicId, notify: enable });
    }

    write(uuid, serviceId, characteristicId, data, encoding = 'utf8') {
        let hexData = '';
        if (Buffer.isBuffer(data)) {
            hexData = data.toString('hex');
        } else if (typeof data === 'string') {
            if (encoding === 'hex') {
                hexData = data;
            } else {
                hexData = Buffer.from(data, encoding).toString('hex');
            }
        }
        this.sendCommand('write', { uuid, service: serviceId, characteristic: characteristicId, data: hexData });
    }

    connect(uuid) {
        this.sendCommand('connect', { uuid });
    }

    disconnect(uuid) {
        this.sendCommand('disconnect', { uuid });
    }
}

module.exports = new BluetoothManager();
