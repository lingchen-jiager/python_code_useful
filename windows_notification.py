# windows简单弹窗提醒
def show_notification(title, message):
    ctypes.windll.user32.MessageBoxW(0, message, title, 0x40 | 0x1)

show_notification("提醒","提醒内容")
