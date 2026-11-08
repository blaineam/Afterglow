#!/usr/bin/env python3
"""Writes the Monkr projects that frame the App Store screenshots (not committed: Monkr embeds the
images in them): the iPhone on its side, as Afterglow runs, and the watch; the sunset's colours, no
captions, as across the owner's other listings. `monkr render` fills in the screenshots."""
import json, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'ios-native/docs/appstore-screenshots')
os.makedirs(out, exist_ok=True)
GRADIENT = ('radial-gradient(ellipse 60% 70% at 50% 108%, rgba(255,110,168,0.62) 0%, transparent 70%), '
            'radial-gradient(ellipse 40% 42% at 50% 18%, rgba(255,212,92,0.20) 0%, transparent 72%), '
            'linear-gradient(180deg, #0b0620 0%, #2a0f4a 52%, #5a1a5e 100%)')
def project(width, height, padding, device, color, scale, rotation, shadow):
    return {
        'version': 3,
        'background': {'type': 'gradient', 'solidColor': '#0b0620', 'gradientCss': GRADIENT, 'gradientName': 'Afterglow', 'imageUrl': None},
        'canvasSize': {'width': width, 'height': height, 'presetName': 'Custom'},
        'padding': padding,
        'exportConfig': {'scale': 1, 'format': 'png'},
        'textOverlay': {}, 'textBlocks': [],
        'sceneObjects': [{
            'id': 'obj-1', 'deviceId': device, 'deviceColorId': color,
            'screenshotUrl': None, 'screenshotFile': None, 'extraScreenshots': [],
            'x': 50, 'y': 50, 'scale': scale, 'rotation': rotation, 'tiltX': 0, 'tiltY': 0,
            'shadow': shadow, 'frameStyle': 'default', 'borderRadius': 16,
            'glow': {'enabled': False, 'color': 'rgba(255,255,255,0.6)', 'blur': 20, 'spread': 2},
        }],
    }
SHADOW = {'enabled': True, 'color': 'rgba(0,0,0,0.5)', 'blur': 60, 'spread': 0, 'offsetX': 0, 'offsetY': 0}
IPHONE_SCALE = float(os.environ.get('IPHONE_SCALE', '1.85'))
json.dump(project(2868, 1320, 40, 'iphone-18-pro-max', 'silver', IPHONE_SCALE, 270, SHADOW), open(os.path.join(out, 'Afterglow-iphone.monkr'), 'w'))
json.dump(project(416, 496, 0, 'apple-watch-series-10-46mm', 'jet-black', 1, 0, dict(SHADOW, blur=24)), open(os.path.join(out, 'Afterglow-watch.monkr'), 'w'))
