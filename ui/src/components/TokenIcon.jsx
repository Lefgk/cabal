// Small inline token logo. Maps symbol → image in /tokens/.
// Falls back to a colored circle with the first letter if unknown.
const LOGOS = {
  WPLS: '/tokens/PLS.png',
  PLS: '/tokens/PLS.png',
  TSTT: '/tokens/PLSX.png',
  PLSX: '/tokens/PLSX.png',
};

export default function TokenIcon({ symbol, size = 16 }) {
  const src = symbol ? LOGOS[symbol.toUpperCase()] : null;
  const style = {
    width: size,
    height: size,
    borderRadius: '50%',
    verticalAlign: 'middle',
    marginRight: 4,
    display: 'inline-block',
    objectFit: 'cover',
  };
  if (src) {
    return <img src={src} alt={symbol} style={style} />;
  }
  // Fallback circle with first letter
  return (
    <span
      style={{
        ...style,
        background: 'var(--accent, #7c3aed)',
        color: 'white',
        fontSize: size * 0.55,
        lineHeight: `${size}px`,
        textAlign: 'center',
        fontWeight: 700,
      }}
    >
      {symbol ? symbol[0].toUpperCase() : '?'}
    </span>
  );
}
