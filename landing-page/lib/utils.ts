import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function downloadAndNavigate() {
  // Open download URL in a new tab/window (this will trigger the download)
  window.open('https://github.com/abcwyc/MeetMemo/releases/latest/download/MeetMemo.dmg', '_blank')
  
  // Navigate to download page
  window.location.href = '/download'
}
