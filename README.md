# PrintServerToIntune
PrintServerToIntune is a tool that exports printers from a Windows print server as Intune Win32 Apps and uploads them to your Intune tenant as TCP/IP printers for your Entra-Joined or Hybrid-Joined workstations.

# Instructions
- *This must be ran on your print server or the workstation where the printers are connected
- Download the release from the right side of the screen
- Extract the file contents and run PackageMyPrinters.ps1.
- Select your printers from the gridview, click OK, and follow the rest of the prompts.
- For complete instructions and details, see the blog post - 

# Limitations
- Only works with TCP/IP port printers
- Only the 64-bit drivers are exported
- Printers with drivers not containing a valid INFPath pointing to c:\windows\system32\driverstore will not be exported
