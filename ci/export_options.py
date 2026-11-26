"""Render App Store signing options for the three targets."""
import os
from pathlib import Path
import plistlib
import sys

data = plistlib.loads(Path(__file__).with_name("ExportOptions.plist").read_bytes())
data["teamID"] = os.environ["TEAM_ID"]
app_id = os.environ.get("APP_ID", "com.hgsldswk.screenshotdue")
data["provisioningProfiles"] = {
    app_id: os.environ.get("APP_PROFILE", "ScreenshotDue AppStore"),
    app_id + ".widget": os.environ.get("WIDGET_PROFILE", "ScreenshotDue Widget AppStore"),
    app_id + ".share": os.environ.get("SHARE_PROFILE", "ScreenshotDue Share AppStore"),
}
sys.stdout.buffer.write(plistlib.dumps(data))
