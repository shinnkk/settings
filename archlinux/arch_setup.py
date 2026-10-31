import json
import os
import subprocess

# 設定値が問題ないか確認

json_file="./arch_setup.json"

with open(json_file, "r", encoding="utf-8") as f:
    configs = json.load(f)


class ValidateConfigs:
    def __init__(self, disk_name):
        self.disk_name = disk_name

    def _check_disk(self):
        status = 1

        result = subprocess.check_output(
            ["lsblk", "-Jdpo", "NAME,ID-LINK,SIZE,TYPE"],
            text=True,
        )

        devices = json.loads(result)["blockdevices"]

        disks = [
            [
                device["name"],
                f"/dev/disk/by-id/{device['id-link']}" if device.get("id-link") else "",
                device.get("size") or ""
            ]
            for device in devices
            if device["type"] == "disk"
        ]

        row_name = ["NAME", "ID-LINK", "SIZE"]

        width_name = max(
            len(row_name[0]),
            *(len(name) for name, _, _ in disks),
        ) + 4

        width_id_link = max(
            len(row_name[1]),
            len(self.disk_name),
            *(len(id_link) for _, id_link, _ in disks),
        ) + 4

        target = os.path.realpath(self.disk_name)

        print(
            f"{' ':<2}"
            f"{row_name[0]:<{width_name}}"
            f"{row_name[1]:<{width_id_link}}"
            f"{row_name[2]}"
        )

        for name, id_link, size in disks:
            matched = os.path.realpath(name) == target

            if matched:
                status = 0
                if "/dev/disk/by-id" in self.disk_name:
                    id_link = self.disk_name

            line = (
                f"{'>' if matched else ' ':<2}"
                f"{name:<{width_name}}"
                f"{id_link:<{width_id_link}}"
                f"{size}"
            )

            if matched:
                print(f"\33[36m{line}\033[0m")
            else:
                print(line)

        return status

    def __call__(self):
        if self._check_disk():
            raise ValueError('An invalid value in “disk”')
