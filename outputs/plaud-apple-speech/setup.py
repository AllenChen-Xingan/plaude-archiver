#!/usr/bin/env python3
"""Build the optional Apple Speech helper; never downloads speech assets."""
import pathlib,subprocess,sys,platform
P=pathlib.Path(__file__).resolve().parent;ROOT=P.parents[1]
if sys.platform!='darwin' or int(platform.mac_ver()[0].split('.')[0])<26:raise SystemExit('Apple Speech requires macOS 26 or later.')
sdk=pathlib.Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
if not sdk.exists():sdk=pathlib.Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip())
cache=ROOT/'work/plaud-apple-speech/module-cache';cache.mkdir(parents=True,exist_ok=True)
subprocess.run(['swiftc','-O','-parse-as-library','-sdk',str(sdk),'-target','arm64-apple-macos26.0','-module-cache-path',str(cache),str(P/'SpeechCLI.swift'),'-o',str(P/'apple-speech')],check=True)
print('Apple Speech helper built; assets were not downloaded.')
