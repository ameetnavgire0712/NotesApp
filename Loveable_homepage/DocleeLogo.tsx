const DocleeLogo = ({ size = "default" }: { size?: "small" | "default" | "large" }) => {
  const dimensions = {
    small: { icon: 30, text: "text-lg", gap: "gap-2" },
    default: { icon: 40, text: "text-2xl", gap: "gap-2.5" },
    large: { icon: 56, text: "text-4xl", gap: "gap-3" },
  };

  const d = dimensions[size];

  return (
    <div className={`flex items-center ${d.gap}`}>
      {/* Abstract geometric mark */}
      <div className="relative" style={{ width: d.icon, height: d.icon }}>
        <svg
          viewBox="0 0 56 56"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
          className="w-full h-full"
        >
          <defs>
            <linearGradient id="logo-g1" x1="0%" y1="0%" x2="100%" y2="100%">
              <stop offset="0%" stopColor="hsl(155 70% 50%)" />
              <stop offset="100%" stopColor="hsl(165 55% 35%)" />
            </linearGradient>
            <linearGradient id="logo-g2" x1="0%" y1="100%" x2="100%" y2="0%">
              <stop offset="0%" stopColor="hsl(155 65% 42%)" stopOpacity="0.4" />
              <stop offset="100%" stopColor="hsl(160 60% 40%)" stopOpacity="0.8" />
            </linearGradient>
          </defs>

          {/* Two offset rounded squares — rotated, overlapping */}
          <rect
            x="10" y="10" width="28" height="28" rx="6"
            fill="url(#logo-g1)"
            transform="rotate(0 24 24)"
          />
          <rect
            x="18" y="18" width="28" height="28" rx="6"
            fill="url(#logo-g2)"
            transform="rotate(0 32 32)"
          />
        </svg>
      </div>

      {/* Wordmark */}
      <span className={`font-display font-bold tracking-tight ${d.text}`}>
        <span className="text-foreground">info</span>
        <span className="text-gradient">snap</span>
        <span className="text-muted-foreground font-light">.ai</span>
      </span>
    </div>
  );
};

export default DocleeLogo;
