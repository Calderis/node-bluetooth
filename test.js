const bluetooth = require('./index');

console.log('Starting Bluetooth Manager...');

bluetooth.on('stateChange', (state) => {
    console.log('State changed:', state);
    if (state === 'poweredOn') {
        console.log('Scanning...');
        bluetooth.scan();
    }
});

bluetooth.on('device', (device) => {
    console.log('Device found:', device.name, device.uuid, device.serviceUuids);

    // Example: Select by Name OR ID OR Service
    const targetService = "FFE0".toLowerCase();
    const targetId = "CC84CFDB-36E3-7DBF-F462-2DBB8560D597";

    if (device.uuid === targetId || (device.serviceUuids && device.serviceUuids.find(u => u.includes(targetService)))) {
        console.log('Target found! Connecting...');
        bluetooth.connect(device.uuid);
        bluetooth.stopScan();
    }
});

bluetooth.on('read', (res) => {
    console.log(`Read from ${res.characteristic}: ${res.data} (Hex)`);

    // Convert Hex to String if needed
    const str = Buffer.from(res.data, 'hex').toString('utf8');
    console.log('Decoded:', str);
});

bluetooth.on('connect', (device) => {
    console.log('Connected to:', device.uuid);
    setTimeout(() => {
        console.log('Discovering services...');
        bluetooth.discoverServices(device.uuid);
    }, 1000);
});

bluetooth.on('disconnect', (device) => {
    console.log('Disconnected from device:', device);
});

bluetooth.on('startScanning', () => {
    console.log('Scan started');
    // Stop after 20 seconds
    setTimeout(() => {
        console.log('Stopping scan due to timeout...');
        bluetooth.stopScan();
        // process.exit(0);
    }, 20000);
});

bluetooth.on('stopScanning', () => {
    console.log('Scan stopped');
});

bluetooth.on('services', (data) => {
    console.log('Services discovered:', data);
    if (data.services.length > 0) {
        const serviceUuid = data.services[0]; // Pick first one
        console.log(`Discovering characteristics for service ${serviceUuid}...`);
        bluetooth.discoverCharacteristics(data.uuid, serviceUuid);
    }
});

bluetooth.on('characteristics', (data) => {
    console.log('Characteristics discovered:', data);
    if (data.characteristics.length > 0) {
        const charUuid = data.characteristics[0];

        // Also try reading once
        bluetooth.read(data.uuid, data.service, charUuid);
        // Subscribe to notifications
        bluetooth.subscribe(data.uuid, data.service, charUuid);
    }
});

bluetooth.on('data', (data) => {
    console.log('Received data (notification/read):', data);
    // console.log('Test complete logic here, but keeping open for notifications...');
});

bluetooth.start();