# Sprut Monitor — Zabbix configuration

Zabbix configuration is stored in the repository using the native Zabbix configuration export format.

The repository does not contain a custom JSON model of Zabbix objects.
Zabbix itself is responsible for serialization and import/update semantics.

## Native export

Run:

    powershell.exe -ExecutionPolicy Bypass -File "R:\SprutMonitor\updater\zabbix-export.ps1"

The script reads the managed template names from the release manifest, resolves their IDs through the Zabbix API, calls configuration.export, and saves the native YAML returned by Zabbix.

No Zabbix configuration is changed by the export script.

## Scope

Managed templates:

- Provider
- EcoFlow Station by API
- Mikrotik by SNMP

Production-only data remains protected:

- hosts
- host macros
- host interfaces
- history
- trends
- events
- problems

The next step is to test the native export/import path on DEV before implementing production application logic.
