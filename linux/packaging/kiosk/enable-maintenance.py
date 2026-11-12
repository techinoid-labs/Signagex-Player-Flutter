#!/usr/bin/python3
"""Administrator opt-in; also usable from the appliance-image provisioning step."""
import os
import pathlib
import pwd
import subprocess
import sys
import xml.etree.ElementTree as ET


def add_binding(path):
    tree = ET.parse(path)
    root = tree.getroot()
    namespace = root.tag.split('}')[0] + '}' if '}' in root.tag else ''
    if namespace:
        ET.register_namespace('', namespace[1:-1])
    keyboard = root.find(namespace + 'keyboard')
    if keyboard is None:
        keyboard = ET.SubElement(root, namespace + 'keyboard')
    for binding in keyboard.findall(namespace + 'keybind'):
        if binding.get('key') == 'C-A-m':
            # Reserve this one shortcut; retain all other operator settings.
            keyboard.remove(binding)
    binding = ET.SubElement(keyboard, namespace + 'keybind', key='C-A-m')
    action = ET.SubElement(binding, namespace + 'action', name='Execute')
    ET.SubElement(action, namespace + 'command').text = '/usr/bin/signagex-maintenance'
    # Refuse symlink destinations; never write through a user-selected link.
    if path.is_symlink():
        raise ValueError('Openbox config must be a regular file')
    temporary = path.with_name(path.name + '.signagex-new')
    with temporary.open('x') as output:
        tree.write(output, encoding='unicode', xml_declaration=True)
    temporary.replace(path)


def main():
    if sys.argv[1:2] == ['--user-binding']:
        # Invoked under runuser, so an operator-owned config cannot redirect root writes.
        path = pathlib.Path.home()/'.config/openbox/rc.xml'
        if path.exists():
            add_binding(path)
        return
    if os.geteuid() != 0 or len(sys.argv) != 2:
        raise SystemExit('Usage: sudo enable-maintenance.py <kiosk-user>')
    user = sys.argv[1]
    account = pwd.getpwnam(user)
    if account.pw_uid < 1000:
        raise SystemExit('Use an ordinary kiosk user')
    subprocess.run(['/usr/lib/signagex-player/maintenance-helper', '--configure', user], check=True)
    subprocess.run(['groupadd', '--system', '-f', 'signagex-maintenance'], check=True)
    subprocess.run(['usermod', '-aG', 'signagex-maintenance', user], check=True)
    system_config = pathlib.Path('/etc/xdg/openbox/rc.xml')
    if system_config.exists():
        add_binding(system_config)
    subprocess.run(['runuser', '-u', user, '--', '/usr/bin/python3',
                    str(pathlib.Path(__file__).resolve()), '--user-binding'], check=True)
    print('Maintenance enabled. Sign out/in (or reboot) to apply group and Openbox changes.')
    print('Open with Ctrl+Alt+M; 9700 also works while the player has keyboard focus.')
    print('Keep the device PIN in your operator password manager. There is no shared default PIN.')


if __name__ == '__main__':
    main()
