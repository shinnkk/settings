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

        if disks:
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

        print("Disk")
        print("  " + format_row({col: col for col in columns}))

        for disk in disks:
            matched = os.path.realpath(disk["Path"]) == os.path.realpath(self.disk_name)
            found |= matched

            if matched and self.disk_name.startswith("/dev/disk/by-id/"):
                disk["ID"] = self.disk_name

            line = ("> " if matched else "  ") + format_row(disk)
            print(f"\33[36m{line}\033[0m" if matched else line)

        if not found:
            raise ValueError('An invalid value in “disk”')

    def __call__(self):
        self._check_disk()
