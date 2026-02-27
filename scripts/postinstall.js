const { execSync } = require('child_process');
const os = require('os');
const path = require('path');

const macBinary = path.join(__dirname, '../drivers/mac');
const winBinary = path.join(__dirname, '../drivers/win.exe');

try {
  if (os.platform() === 'darwin') {
    execSync(`chmod +x "${macBinary}"`, { stdio: 'inherit' });
    console.log('Made mac binary executable.');
  } else if (os.platform() === 'win32') {
    // No action needed for .exe files
    console.log('Windows platform detected, no chmod needed.');
  } else {
    // Linux or other: if needed, add logic here
    console.log('No postinstall actions for this platform.');
  }
} catch (err) {
  console.warn('Could not set executable permissions:', err.message);
}
