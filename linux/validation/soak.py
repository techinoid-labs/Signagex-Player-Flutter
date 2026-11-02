#!/usr/bin/env python3
"""Bounded, read-only lab soak. Stores summaries, never raw player payloads."""
import argparse, collections, json, os, pathlib, shutil, signal, subprocess, time


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=10).strip()


def inspect(home, started, expected_build):
    problems, warnings = [], []
    properties = dict(line.split('=',1) for line in command('systemctl','--user','show','signagex-player',
        '-p','MainPID','-p','NRestarts','-p','ActiveState').splitlines() if '=' in line)
    pid = int(properties.get('MainPID','0'))
    if properties.get('ActiveState') != 'active' or pid <= 0: problems.append('player_not_active')
    state = home/'.local/share/signagex-player'
    health = json.loads((state/'health.json').read_text())
    age = time.time()-health.get('timestamp',0)
    if health.get('pid') != pid or not 0 <= age < 45: problems.append('health_stale_or_wrong_pid')
    if health.get('build') != expected_build: problems.append('unexpected_build')
    rss = None
    if pid > 0:
        for line in pathlib.Path(f'/proc/{pid}/status').read_text().splitlines():
            if line.startswith('VmRSS:'): rss=int(line.split()[1])/1024
    temperature = None
    thermal = pathlib.Path('/sys/class/thermal')
    readings = {}
    for zone in thermal.glob('thermal_zone*'):
        try:
            kind=(zone/'type').read_text().strip()
            if kind in ('x86_pkg_temp','cpu-thermal','cpu_thermal','TCPU'):
                readings[kind]=float((zone/'temp').read_text())/1000
        except (OSError,ValueError): pass
    for kind in ('x86_pkg_temp','cpu-thermal','cpu_thermal','TCPU'):
        if kind in readings: temperature=readings[kind];break
    if temperature is not None and temperature >= 85: warnings.append('cpu_temperature_at_least_85C')
    throttles = 0
    for path in pathlib.Path('/sys/devices/system/cpu').glob('cpu[0-9]*/thermal_throttle/core_throttle_count'):
        try: throttles += int(path.read_text())
        except (OSError,ValueError): pass
    free = shutil.disk_usage(home).free
    if free < 512*1024*1024: problems.append('storage_below_512MiB')
    logs = command('journalctl','--user','-u','signagex-player','--since',f'@{started}',
        '--no-pager','-o','cat','--grep','segfault|SIGSEGV|page check unavailable|Unhandled exception|Framework error')
    if logs: problems.append('error_markers_in_soak_window')
    preferences = json.loads((state/'shared_preferences.json').read_text())
    configuration = json.loads(preferences.get('flutter.linux_configuration','{}'))
    return {'timestamp':time.time(),'pid':pid,'restarts':int(properties.get('NRestarts','0')),
        'build':health.get('build'),'health_age_seconds':round(age,2),'rss_MiB':rss,
        'cpu_temperature_C':temperature,'core_throttle_count':throttles,'free_bytes':free,
        'configuration_revision':configuration.get('revision'),
        'setting_outcomes':dict(collections.Counter(value.get('status','unknown') for value in configuration.get('results',{}).values())),
        'automatic_updates':configuration.get('values',{}).get('apply_app_updates') is True,
        'debug_log_bytes':(state/'signagex_debug.log').stat().st_size if (state/'signagex_debug.log').exists() else 0,
        'problems':problems,'hardware_warnings':warnings}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--hours',type=float,default=24)
    parser.add_argument('--interval',type=int,default=60)
    parser.add_argument('--build',required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True)
    args=parser.parse_args()
    if not 0 < args.hours <= 48 or not 5 <= args.interval <= 300: parser.error('hours must be 0–48 and interval 5–300 seconds')
    os.umask(0o077)
    args.output.mkdir(parents=True,exist_ok=False)
    stopped=False
    def stop(*_):
        nonlocal stopped
        stopped=True
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    started=time.time(); deadline=time.monotonic()+args.hours*3600
    first=None;count=failures=0;last=None
    def report(status):
        temporary=args.output/'report.json.tmp'
        temporary.write_text(json.dumps({'status':status,'expected_build':args.build,'started':started,
            'updated':time.time(),'required_hours':args.hours,'samples':count,'failed_samples':failures,
            'latest':last},indent=2)+'\n')
        temporary.replace(args.output/'report.json')
    report('running')
    while not stopped:
        try:
            last=inspect(pathlib.Path.home(),started,args.build)
            if first is None: first=last.copy()
            if last['restarts']>first['restarts'] or last['pid']!=first['pid']: last['problems'].append('player_restarted_during_soak')
            if last['core_throttle_count']>first['core_throttle_count']: last['hardware_warnings'].append('hardware_throttled_during_soak')
        except Exception as error:
            last={'timestamp':time.time(),'problems':['inspection_failed:'+type(error).__name__]}
        count+=1
        if last['problems']:failures+=1
        with (args.output/'samples.jsonl').open('a') as stream: stream.write(json.dumps(last)+'\n')
        report('running')
        remaining=deadline-time.monotonic()
        if remaining <= 0:break
        # Short waits allow service cancellation to flush an honest report.
        until=time.monotonic()+min(args.interval,remaining)
        while not stopped and time.monotonic()<until:time.sleep(min(1,until-time.monotonic()))
    report('interrupted' if stopped else 'failed' if failures else 'passed')
    return 1 if stopped or failures else 0

if __name__=='__main__':raise SystemExit(main())
