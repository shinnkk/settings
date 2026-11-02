import json
import os
import subprocess
from pathlib import Path

# 設定値が問題ないか確認
class ValidateConfigs:
    def __init__(self, configs):
        self.disk_name = configs["diskName"]
        self.time_zone = configs["timeZone"]
        self.keyboard_layout = configs["keyboardLayout"]
        self.host_name = configs["hostName"]
        self.user_name = configs["userName"]
        self.packages = configs["packages"]
        self.aur_packages = configs["aurPackages"]
        self.luks_password_file = configs["luksPasswordFile"]
        self.user_password_file = configs["userPasswordFile"]
        self.zsh_config_file = configs["zshConfigFile"]
        self.font_config_file = configs["fontConfigFile"]

    def _check_disk_name(self):
        result = subprocess.check_output(
            ["lsblk", "-Jdpo", "MODEL,NAME,TRAN,SIZE,ID-LINK,TYPE"],
            text=True,
        )

        disks = [
            {
                "Model": d.get("model") or "",
                "Path": d.get("name") or "",
                "Transport": d.get("tran") or "",
                "Size": d.get("size") or "",
                "ID": f"/dev/disk/by-id/{d['id-link']}" if d.get("id-link") else "",
            }
            for d in json.loads(result)["blockdevices"]
            if d.get("type") == "disk"
        ]

        if not disks:
            raise RuntimeError('No disks found')

        columns = ("Model", "Path", "Transport", "Size", "ID")

        widths = {
            col: max(len(col), *(len(d[col]) for d in disks))
            for col in columns[:-1]
        }

        def format_row(row):
            return "  ".join(
                f"{row[col]:<{widths[col]}}"
                for col in columns[:-1]
            ) + "  " + row["ID"]

        found = False

        print("Disk:")
        print("  " + format_row({col: col for col in columns}))

        for disk in disks:
            matched = os.path.realpath(disk["Path"]) == os.path.realpath(self.disk_name)
            found |= matched

            if matched and self.disk_name.startswith("/dev/disk/by-id/"):
                disk["ID"] = self.disk_name

            line = ("> " if matched else "  ") + format_row(disk)
            print(f"\33[36m{line}\033[0m" if matched else line)

        if not found:
            raise ValueError('Invalid config: “diskName”')

    def _check_time_zone(self):
        base = Path("/usr/share/zoneinfo")
        file = Path(base / self.time_zone)

        if not file.is_file():
            raise ValueError('Invalid config: “timeZone”')

        print(f"Timezone:  {self.time_zone}")

    def _check_keyboard_layout(self):
        base = Path("/usr/share/kbd/keymaps/i386/qwerty")
        file = Path(base / self.keyboard_layout)

        if not file.is_file():
            raise ValueError('Invalid config: "keyboardLayout”')

        print(f"Keyboard layout:  {self.keyboard_layout}")

    def _check_host_name(self):
        if not len(self.host_name):
            raise ValueError('Invalid config: "hostName"')

        print(f"Hostname:  {self.host_name}")

    def _check_user_name(self):
        if not len(self.user_name):
            raise ValueError('Invalid config: "userName"')

        print(f"Username:  {self.user_name}")

    def _check_packages(self):
        pass
    def _check_aur_packages(self):
        pass
    def _check_luks_password_file(self):
        pass
    def _check_user_password_file(self):
        pass
    def _check_zsh_config_file(self):
        pass
    def _check_font_config_file(self):
        pass

    def __call__(self):
        self._check_disk_name()
        self._check_time_zone()
        self._check_keyboard_layout()
        self._check_host_name()
        self._check_user_name()
        self._check_packages()
        self._check_aur_packages()
        self._check_luks_password_file()
        self._check_user_password_file()
        self._check_zsh_config_file()
        self._check_font_config_file()


if __name__ == "__main__":
    json_file="./arch_setup.json"

    with open(json_file, "r", encoding="utf-8") as f:
        configs = json.load(f)

    ValidateConfigs(configs)()
