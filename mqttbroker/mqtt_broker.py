import asyncio
import logging
from logging.handlers import RotatingFileHandler
import os
import sys
from amqtt.broker import Broker

# --- 1. 获取当前程序所在的绝对目录（兼容 PyInstaller 打包与直接运行） ---
if getattr(sys, 'frozen', False):
    # 如果是 PyInstaller 打包后的 exe / 二进制运行环境
    current_dir = os.path.dirname(sys.executable)
else:
    # 如果是直接用 python 脚本运行
    current_dir = os.path.dirname(os.path.abspath(__file__))

# --- 2. 动态读取端口号文件 ---
port_file_path = os.path.join(current_dir, "mqttbroker.port")
passwd_file_path = os.path.join(current_dir, "passwd.txt")

try:
    with open(port_file_path, mode="r+", encoding="utf-8") as fe:
        port = fe.read().strip()  # 使用 .strip() 剥离多余的换行符和空格
        print(123)
        print(port)
        print("端口号是:" + port)
except FileNotFoundError:
    print(f"错误: 找不到端口配置文件 {port_file_path}")
    sys.exit(1)

# --- 3. 配置日志自动轮转（存放在程序同级目录下） ---
log_file = os.path.join(current_dir, 'broker.log')
handler = RotatingFileHandler(log_file, maxBytes=1024*1024, backupCount=3)
handler.setFormatter(logging.Formatter('%(asctime)s [%(levelname)s] %(name)s: %(message)s'))

# 设置全局日志
logger = logging.getLogger()
logger.setLevel(logging.INFO)
logger.addHandler(handler)

# 同时在控制台打印一份
console_handler = logging.StreamHandler()
console_handler.setFormatter(logging.Formatter('%(asctime)s [%(levelname)s] %(name)s: %(message)s'))
logger.addHandler(console_handler)

# --- 4. 配置 AMQTT（绑定动态路径） ---
config = {
    'listeners': {
        'default': {
            'type': 'tcp',
            'bind': f'0.0.0.0:{port}',
        }
    },
    'sys_interval': 0,
    'auth': {
        'allow-anonymous': False,
        'password-file': passwd_file_path  # 使用同级目录下的绝对路径密码文件
    }
}

async def main():
    broker = Broker(config)
    await broker.start()
    logging.info(f"MQTT Broker with Authentication started on port {port}...")
    while True:
        await asyncio.sleep(3600)

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logging.info("Broker stopped.")
