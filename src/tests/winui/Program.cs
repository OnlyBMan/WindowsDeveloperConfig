using System;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HelloWinUI;

public class App : Application
{
    private Window? _window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var root = new Grid();
        _window = new Window
        {
            Title = "WinUI",
            Content = root,
        };

        root.Loaded += OnRootLoaded;
        _window.Activate();
    }

    private async void OnRootLoaded(object sender, RoutedEventArgs e)
    {
        var root = (FrameworkElement)sender;
        root.Loaded -= OnRootLoaded;

        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot,
            Title = "WinUI",
            Content = $"WinUI: {typeof(Application).Name}",
            CloseButtonText = "OK",
        };

        await dialog.ShowAsync();
        _window?.Close();
        Exit();
    }
}

public static class Program
{
    [STAThread]
    public static void Main()
    {
        Application.Start(p =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            System.Threading.SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
    }
}
