<img width="509" height="183" alt="PrintServerToIntune" src="https://github.com/user-attachments/assets/57eb7103-36b3-45f7-bdc3-d915d7a76f6e" />

# My Fork:
- Added toggle to default printers to B&W.
- Added toggle to default to simplex (duplex is default typically).
- Added line to unblock downloaded Intune packager.
- Copies printer icon into printer directories to speed up manual importing.

# PrintServerToIntune
PrintServerToIntune is a tool that exports printers from a Windows print server (or workstation) as Intune Win32 Apps and uploads them to your Intune tenant as TCP/IP printers for your Entra-Joined or Hybrid-Joined workstations.

# Instructions
- *This must be run on your print server or the workstation where the printers are connected
- Download the release from the right side of the screen
- Extract the file contents and run PackageMyPrinters.ps1.
- Select your printers from the gridview, click OK, and follow the rest of the prompts.
- For complete instructions and details, see the blog post - https://smbtothecloud.com/printservertointune-migrate-printers-to-intune-as-tcp-ip-connections/

# Limitations
- Only works with TCP/IP port printers
- Only the 64-bit drivers are exported
- Printers with drivers not containing a valid INFPath pointing to c:\windows\system32\driverstore will not be exported
