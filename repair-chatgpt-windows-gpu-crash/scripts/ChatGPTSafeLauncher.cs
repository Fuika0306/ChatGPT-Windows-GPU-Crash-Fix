using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace ChatGPTSafeLauncher
{
    [Flags]
    internal enum ActivateOptions
    {
        None = 0
    }

    [ComImport]
    [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);
    }

    internal static class NativeMethods
    {
        [DllImport("ole32.dll")]
        internal static extern int CoAllowSetForegroundWindow(
            [MarshalAs(UnmanagedType.IUnknown)] object unknown,
            IntPtr reserved);
    }

    internal static class Program
    {
        private const string DefaultAumid =
            "OpenAI.Codex_2p2nqsd0c76g0!App";
        private const string ChromiumArguments =
            "--allow-third-party-modules";

        [STAThread]
        private static int Main(string[] arguments)
        {
            string aumid = arguments.Length > 0 &&
                           !String.IsNullOrWhiteSpace(arguments[0])
                ? arguments[0]
                : DefaultAumid;

            try
            {
                Type activationManagerType = Type.GetTypeFromCLSID(
                    new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C"),
                    true);
                var manager =
                    (IApplicationActivationManager)Activator.CreateInstance(
                        activationManagerType);

                NativeMethods.CoAllowSetForegroundWindow(
                    manager,
                    IntPtr.Zero);

                uint processId;
                int result = manager.ActivateApplication(
                    aumid,
                    ChromiumArguments,
                    ActivateOptions.None,
                    out processId);

                if (result < 0)
                {
                    Marshal.ThrowExceptionForHR(result);
                }

                Thread.Sleep(1500);
                return 0;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "ChatGPT launch failed.\r\n\r\n" +
                    exception.Message +
                    "\r\n\r\nHRESULT: 0x" +
                    Marshal.GetHRForException(exception).ToString("X8"),
                    "ChatGPT GPU Safe Launcher",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
