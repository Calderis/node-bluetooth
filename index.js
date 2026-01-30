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
            const compiledPath = path.join(__dirname, 'drivers', 'mac');

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
            // Windows: Attempt to spawn a compiled driver or the placeholder.
            // Ideally, we would check for 'drivers/win.exe'
            const exePath = path.join(__dirname, 'drivers', 'win.exe');
            const fs = require('fs');
            if (fs.existsSync(exePath)) {
                cmd = exePath;
                args = [];
            } else {
                console.warn("Windows driver not compiled. Please run 'npm run compile:win' on your Windows machine to compile drivers/win.cs");
                // Prevent crash loop by not spawning or spawning a dummy
                return;
            }
            // // Windows: Run PowerShell driver (no compilation needed)
            // cmd = 'powershell';
            // args = [
            //     '-NoProfile',
            //     '-ExecutionPolicy', 'Bypass',
            //     '-File', path.join(__dirname, 'drivers', 'win.ps1')
            // ];
        } else {
            throw new Error(`Platform ${platform} not supported`);
        }

        this.process = spawn(cmd, args);
        this.isStarted = true;

        this.process.stdout.on('data', (data) => {
            this.handleData(data);
            // console.log(`[BT Driver]: ${data}`);
        });

        this.process.stderr.on('data', (data) => {
            // console.error(`[BT Driver Error]: ${data}`);
        });

        this.process.on('close', (code) => {
            this.isStarted = false;
            // console.log(`Driver process exited with code ${code}`);
        });
    }

    stop() {
        if (this.process) {
            this.process.kill();
            this.process = null;
            this.isStarted = false;
        }
    }

    handleData(data) {
        this.buffer += data.toString();
        const lines = this.buffer.split('\n');
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
            // console.log('Unknown event:', msg);
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
