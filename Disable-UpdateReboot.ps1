<#
.SYNOPSIS
    Disable Windows update auto reboot
.DESCRIPTION
    This script disables and sets permissions on registry key and task files to prevent the system
    from re-enabling reboot task
.NOTES
    Script will have to be run again after feature updates. This is because windows wipes the windows directory during it's update process.
    This script was created by SCUR0
.LINK
    https://github.com/SCUR0/PowerShell-Scripts
#>

[cmdletbinding()]
param ()

If (!([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).`
      IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")){
        Write-Error "Admin permissions are required to run this script. Please open powershell as administrator."
        pause
        break
}

#Variables
$Errors=$null
$RebootTaskError=$null
$RebootRegKey="SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\UpdateOrchestrator\Reboot"
$RebootReg="Registry::HKEY_LOCAL_MACHINE\$RebootRegKey"
$RebootTask="$env:WinDir\System32\Tasks\Microsoft\Windows\UpdateOrchestrator\Reboot"
$RegAdminRule = New-Object System.Security.AccessControl.RegistryAccessRule ("BUILTIN\Administrators","FullControl","Allow")
$RegSystemRule = New-Object System.Security.AccessControl.RegistryAccessRule ("System","ReadKey","Allow")
$RegUserRule = New-Object System.Security.AccessControl.RegistryAccessRule ($env:USERNAME,"FullControl","Allow")
$FileAdminRule = New-Object System.Security.AccessControl.filesystemaccessrule ("BUILTIN\Administrators","FullControl","Allow")
$FileSystemRule = New-Object System.Security.AccessControl.filesystemaccessrule ("System","ReadAndExecute","Allow")
$FileUserRule = New-Object System.Security.AccessControl.filesystemaccessrule ($env:USERNAME,"FullControl","Allow")
$owner = [Security.Principal.NTAccount]$env:USERNAME


Function Enable-Privilege {
  param($Privilege)
  $Definition = @'
using System;
using System.Runtime.InteropServices;
public class AdjPriv {
  [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
  internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
    ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr rele);
  [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
  internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
  [DllImport("advapi32.dll", SetLastError = true)]
  internal static extern bool LookupPrivilegeValue(string host, string name,
    ref long pluid);
  [StructLayout(LayoutKind.Sequential, Pack = 1)]
  internal struct TokPriv1Luid {
    public int Count;
    public long Luid;
    public int Attr;
  }
  internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
  internal const int TOKEN_QUERY = 0x00000008;
  internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
  public static bool EnablePrivilege(long processHandle, string privilege) {
    bool retVal;
    TokPriv1Luid tp;
    IntPtr hproc = new IntPtr(processHandle);
    IntPtr htok = IntPtr.Zero;
    retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
      ref htok);
    tp.Count = 1;
    tp.Luid = 0;
    tp.Attr = SE_PRIVILEGE_ENABLED;
    retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
    retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero,
      IntPtr.Zero);
    return retVal;
  }
}
'@
  $ProcessHandle = (Get-Process -id $pid).Handle
  $type = Add-Type $definition -PassThru
  $type[0]::EnablePrivilege($processHandle, $Privilege)
}

#verify task is created
If (!(test-path $RebootTask)){
    Write-Output "Reboot task has to first be created by windows update in order to disable. Please run script after first cumulative update."
}else{
    do {} until (Enable-Privilege SeTakeOwnershipPrivilege)


    #SET ACL for registry key
    #Set ownership
    Write-Verbose "Modifying registry keys." -Verbose
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($RebootRegKey,`
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[System.Security.AccessControl.RegistryRights]::TakeOwnership)
    $RegACL = $key.GetAccessControl()
    if ($null -eq $RegACL){
        Write-Warning "Error encountered while trying to modify registry for reboot"
        $Errors=$true
    }else{
        $RegACL.SetOwner($owner)
        $key.SetAccessControl($RegACL)

        #Modify permissions
        $RegACL = $key.GetAccessControl()
        $RegACL.ResetAccessRule($RegAdminRule)
        $RegACL.SetAccessRule($RegSystemRule)
        $RegACL.SetAccessRule($RegUserRule)
        $key.SetAccessControl($RegACL)

        #remove inheritance
        $RegACL = Get-Acl -Path $RebootReg
        $RegACL.SetAccessRuleProtection($true,$false)
        $RegACL | Set-Acl
    }

    #SET ACL for task file
    #Change owner
    Write-Verbose "Modifying scheduled task files." -Verbose
    $FileACL = Get-ACL -Path $RebootTask -ErrorAction SilentlyContinue
    if ($null -eq $FileACL){
        Write-Warning "Error encountered while trying to modify task file for reboot"
        $Errors=$true
    }else{
        $FileACL.SetOwner($owner)
        Set-Acl -Path $RebootTask -AclObject $FileACL

        #remove inheritance 
        $FileACL = Get-Acl -Path $RebootTask
        $FileACL.SetAccessRuleProtection($true,$false)
        $FileACL | Set-Acl -ErrorAction Stop

        #remove and set permissions
        $FileACL = Get-ACL -Path $RebootTask
        $FileACL.Access | %{$FileACL.RemoveAccessRule($_)} |Out-Null
        $FileACL.SetAccessRule($FileAdminRule)
        $FileACL.SetAccessRule($FileSystemRule)
        $FileACL.SetAccessRule($FileUserRule)
        Set-Acl -Path $RebootTask -AclObject $FileACL
    }
    if (!$Errors){
        #attempt to set task to disabled
        Write-Verbose "Attempting to set task to disabled via task scheduler." -Verbose
        try{
            Get-ScheduledTask Reboot -ErrorAction Stop | Disable-ScheduledTask -ErrorAction Stop | Out-Null
        }catch{
            $RebootTaskError=$true
        }
        if (!$RebootTaskError){
            #remove admin permissions
            Write-Verbose "Restricting security permisions on registry and task file." -Verbose
            $RegACL.RemoveAccessRule($RegAdminRule) | Out-Null
            $key.SetAccessControl($RegACL)

            $FileACL.RemoveAccessRule($FileAdminRule) | Out-Null
            Set-Acl -Path $RebootTask -AclObject $FileACL

            Write-Verbose "Script complete." -Verbose
            Write-Warning "Script will need to be run again after a feature (new windows build) update."
        }
    }else{
        Write-Output "Errors were encountered while attempting to make changes. The script was not successful."
    }
    }
