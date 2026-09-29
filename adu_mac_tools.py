# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-e678c17c9f2757671b810f4be4a1c4769f0db644ac5512b60d4591983da48d15"
# Source-SHA256: "0f097f92eb589a45524edeb4474e0202c5ede28d0056188e8305f6efd0ca4657"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
import subprocess
import time

def send_wechat(contact: str, message: str) -> dict:
    subprocess.run(['open', '-a', 'WeChat'])
    time.sleep(2)
    
    subprocess.run(['pbcopy'], input=contact.encode('utf-8'))
    script1 = '''
    tell application "WeChat" to activate
    delay 1
    tell application "System Events"
        tell process "WeChat"
            keystroke "f" using {command down}
            delay 1
            keystroke "v" using {command down}
            delay 1
            key code 36
            delay 1
            key code 36
            delay 1
        end tell
    end tell
    '''
    subprocess.run(['osascript', '-e', script1])
    time.sleep(1)
    
    subprocess.run(['pbcopy'], input=message.encode('utf-8'))
    script2 = '''
    tell application "System Events"
        tell process "WeChat"
            keystroke "v" using {command down}
            delay 0.5
            key code 36
        end tell
    end tell
    '''
    subprocess.run(['osascript', '-e', script2])
    return {"success": True, "contact": contact, "message": message}

def open_app(app_name: str) -> dict:
    subprocess.run(['open', '-a', app_name])
    return {"success": True, "app": app_name}

def run_terminal(command: str) -> dict:
    result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=30)
    return {"success": True, "output": result.stdout or result.stderr}

def send_email(to: str, subject: str, body: str) -> dict:
    """发邮件"""
    script = f'''
    tell application "Mail"
        set newMsg to make new outgoing message with properties {{subject:"{subject}", content:"{body}", visible:false}}
        tell newMsg
            make new to recipient with properties {{address:"{to}"}}
        end tell
        send newMsg
    end tell
    '''
    subprocess.run(['osascript', '-e', script])
    return {"success": True}

def create_reminder(title: str, notes: str = "") -> dict:
    """创建备忘录"""
    script = f'''
    tell application "Reminders"
        make new reminder with properties {{name:"{title}", body:"{notes}"}}
    end tell
    '''
    subprocess.run(['osascript', '-e', script])
    return {"success": True}

def create_note(title: str, body: str) -> dict:
    """创建备忘录笔记"""
    subprocess.run(['pbcopy'], input=body.encode('utf-8'))
    script = f'''
    tell application "Notes"
        make new note with properties {{name:"{title}"}}
        tell note 1 of folder "Notes"
            set body to "{body}"
        end tell
    end tell
    '''
    subprocess.run(['osascript', '-e', script])
    return {"success": True}

def take_screenshot() -> dict:
    """截屏保存到桌面"""
    import datetime
    path = f"~/Desktop/screenshot_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
    subprocess.run(['screencapture', path])
    return {"success": True, "path": path}

def create_calendar_event(title: str, date: str, notes: str = "") -> dict:
    """创建日历事件"""
    script = f'''
    tell application "Calendar"
        tell calendar "Home"
            make new event with properties {{summary:"{title}", start date:(current date), description:"{notes}"}}
        end tell
    end tell
    '''
    subprocess.run(['osascript', '-e', script])
    return {"success": True}

def get_clipboard() -> dict:
    """获取剪贴板内容"""
    result = subprocess.run(['pbpaste'], capture_output=True, text=True)
    return {"success": True, "content": result.stdout}

def set_volume(level: int) -> dict:
    """设置音量 0-100"""
    script = f'set volume output volume {level}'
    subprocess.run(['osascript', '-e', script])
    return {"success": True, "volume": level}

def lock_screen() -> dict:
    """锁定屏幕"""
    subprocess.run(['pmset', 'displaysleepnow'])
    return {"success": True}
