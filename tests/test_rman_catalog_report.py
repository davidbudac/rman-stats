"""Offline wrapper contract tests. Does not execute or validate Oracle SQL."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def preview_html(rows):
    lines = []
    for line in (ROOT / 'rman_catalog_report_html.sql').read_text().splitlines():
        if not line.startswith('prompt '):
            continue
        line = line[7:]
        lines.append(line)
        if 'id="metadata"' in line:
            lines.append(json.dumps(dict(dbid='123456789', name='DEMO', **{'from': '2026-10-01 00:00:00', 'to': '2026-10-22 00:00:00'})))
        if 'id="records"' in line:
            lines.extend(json.dumps(r).replace('<', '\\u003c') for r in rows)
    return '\n'.join(lines).replace('<h1>RMAN catalog report</h1>', '<h1>RMAN catalog report — synthetic preview</h1>')


class WrapperTests(unittest.TestCase):
    def test_sqlplus_bind_types(self):
        # SQL*Plus VARIABLE supports no DATE type (unlike PL/SQL variables).
        sql = (ROOT / 'rman_catalog_report_html.sql').read_text()
        declarations = [line.lower().split() for line in sql.splitlines()
                        if line.lower().startswith('variable ')]
        supported = {'number', 'varchar2(19)'}
        for declaration in declarations:
            self.assertIn(declaration[2], supported)

    def test_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            fake = work / 'sqlplus'
            fake.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
s=sys.stdin.read()
assert 'RMAN_CATALOG_PASSWORD' not in os.environ
assert 'SQLPATH' not in os.environ
assert sys.argv[1:]==['-S','-L','-R','1','/nolog']
assert 'as sysdba' not in s
assert '@report.sql 123456789 90' in s
mode=os.environ.get('FAKE_MODE','ok')
if mode=='login':
 print('ORA-01017 deliberately-sensitive-diagnostic');sys.exit(1)
if mode=='sp2':
 print('RMANCAT_CONNECTED')
 print('SP2-0734: bad command')
Path('report.html').write_text('<html>'+('' if mode=='partial' else '<!-- report-complete -->')+'</html>')
''')
            fake.chmod(0o700)
            env = {**os.environ, 'PATH': str(work) + os.pathsep + os.environ['PATH'],
                   'RMAN_CATALOG_PASSWORD': 'test-secret', 'SQLPATH': '/untrusted'}
            cmd = ['sh', str(ROOT / 'rman_catalog_report.sh'), '-c', 'rco@cat', '-b', '123456789', '-o', str(work / 'out')]
            success = subprocess.run(cmd, env=env, capture_output=True, text=True)
            self.assertEqual(success.returncode, 0, success.stderr)
            self.assertTrue(Path(success.stdout.strip()).is_file())
            for mode in ['login', 'sp2', 'partial']:
                result = subprocess.run(cmd, env={**env, 'FAKE_MODE': mode}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, mode)
                self.assertEqual(result.stdout, '')
                self.assertNotIn('deliberately-sensitive-diagnostic', result.stderr)
                if mode == 'login':
                    self.assertIn('before login completed', result.stderr)
                    self.assertIn('ORA-01017', result.stderr)
                if mode == 'sp2':
                    self.assertIn('after login completed', result.stderr)
                    self.assertIn('SP2-0734', result.stderr)
            for value in ['', '1;exit', '-1', '0', '12345678901']:
                result = subprocess.run(['sh', str(ROOT / 'rman_catalog_report.sh'), '-c', '/@cat', '-b', value], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
