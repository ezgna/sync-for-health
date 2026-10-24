#!/usr/bin/env python3
"""Run the production SyncJob, Batch, Payload and AnchorStore with fake HealthKit/HTTP.
No iPhone, real health data, network, signing, or user preferences are accessed.
"""
from pathlib import Path
import subprocess
import tempfile
import os
import shutil
import shlex

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='health-sync-contract-') as temporary:
    out = Path(temporary)
    source = (root / 'SaluteLibera/Sync/SyncEngine.swift').read_text()
    source = source[source.index('actor SyncCoordinator {'):source.index('/// Prova di connessione:')]
    source = source.replace('UserDefaults.standard', 'TestDefaults.standard')
    store = (root / 'SaluteLibera/Model/Stores.swift').read_text()
    store = store[store.index('final class AnchorStore'):store.index('/// Una voce del registro')]
    # Linux/macOS fixtures have no iOS file-protection flag; all store control
    # flow, disk writes, exceptions and cache assignment remain production code.
    store = store.replace(', .completeFileProtectionUntilFirstUserAuthentication', '')
    background = (root / 'SaluteLibera/Sync/Background.swift').read_text()
    background = background[background.index('@MainActor\nenum HealthBackground'):background.index('/// BGAppRefreshTask')]
    demo = (root / 'SaluteLibera/Demo/DemoData.swift').read_text()
    demo = demo[demo.index('    static func runDemoSync('):demo.index('\n}\n\n/// Accende e spegne')]
    extended = (root / 'SaluteLibera/Sync/ExtendedSync.swift').read_text().replace('import HealthKit\n', '')
    transport = (root / 'SaluteLibera/Sync/RecordTransport.swift').read_text()
    (out / 'Production.swift').write_text('import Foundation\n' + source + '\n' + store + '\n' + background
                                         + '\nenum DemoData {\n' + demo + '\n}\n' + extended + '\n' + transport)
    (out / 'Payload.swift').write_text((root / 'SaluteLibera/Model/Payload.swift').read_text())
    binary = out / 'contracts'
    subprocess.run(['swiftc', '-g', '-swift-version', '5', '-parse-as-library', *shlex.split(os.environ.get('SYNC_CONTRACT_SWIFT_FLAGS', '')),
                    str(out / 'Production.swift'), str(out / 'Payload.swift'),
                    str(root / 'tests/SyncHarness.swift'), '-o', str(binary)], check=True)
    if os.environ.get('SYNC_CONTRACT_KEEP_DIR'):
        kept = Path(os.environ['SYNC_CONTRACT_KEEP_DIR'])
        kept.mkdir(parents=True, exist_ok=True)
        for name in ['Production.swift', 'Payload.swift', 'contracts']:
            shutil.copy2(out / name, kept / name)
        shutil.copy2(root / 'tests/SyncHarness.swift', kept / 'SyncHarness.swift')
    try:
        subprocess.run([str(binary)], check=True, cwd=out)
    except subprocess.CalledProcessError:
        evidence = Path(os.environ.get('SYNC_CONTRACT_FAILURE_DIR', str(root.parent.parent / 'work' / 'sync-contract-failure')))
        evidence.mkdir(parents=True, exist_ok=True)
        for name in ['Production.swift', 'Payload.swift', 'contracts']:
            shutil.copy2(out / name, evidence / name)
        shutil.copy2(root / 'tests/SyncHarness.swift', evidence / 'SyncHarness.swift')
        raise
