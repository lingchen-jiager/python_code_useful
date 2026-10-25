需要保证py文件和passwd.txt文件、mqttbroker.port文件在同一个文件夹下。

mqttbroker.port文件只需要填写一个端口即可。

passwd.txt文件格式为“用户名:哈希过的密码串”，不支持明文密码，必须写加密后的密码。

密码加密可使用：`python3 -c "from pwdlib import PasswordHash; print(PasswordHash.recommended().hash('Your_Password'))`

直接`python mqtt_broker.py`就能运行，

经测试，在alpine3.24版本，128M内存、512M硬盘的机器上运行成功。

这个主要就是自用，只服务于自己的几个设备，不需要一步步的配置mosquitto。



---
为了减少安装python和相关包的步骤，我打包了适用于alpine3.24的程序，不用安装python也能直接运行。
至于passwd.txt文件中需要的哈希字符串，需要你在本地电脑运行以下命令获取：
`python3 -c "from pwdlib import PasswordHash; print(PasswordHash.recommended().hash('Your_Password'))`

mqttbroker.port文件和passwd.txt文件还是要和二进制程序在同一个路径下，然后执行

`chmod +x broker`

`./broker`

就可以运行了。

---
