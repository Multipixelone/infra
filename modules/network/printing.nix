{
  flake.modules.nixos.pc = {
    services.printing.enable = true;

    hardware.printers = {
      ensurePrinters = [
        {
          name = "Brother_HL_L2460DW";
          description = "Brother HL-L2460DW";
          # The driverless queue can pass PDF through unchanged, but this model
          # only has a PCL6 interpreter.  It then prints the PDF bytes as text,
          # producing pages of garbage.  Render to PCL locally and send it over
          # the printer's supported raw port instead.
          deviceUri = "socket://192.168.3.131:9100";
          model = "drv:///sample.drv/generpcl.ppd";
          ppdOptions = {
            PageSize = "Letter";
            Option1 = "True"; # duplexer installed
            Duplex = "DuplexNoTumble"; # two-sided-long-edge
          };
        }
      ];
      ensureDefaultPrinter = "Brother_HL_L2460DW";
    };
  };
}
