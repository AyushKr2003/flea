.pragma library

// QVariant sequences crossing a QML var signal expose list methods without being JavaScript Arrays.
function isList(value) {
    return Array.isArray(value) || (value !== null && typeof value === "object"
        && typeof value.length === "number" && value.length >= 0 && value.length < 4294967296
        && value.length === Math.floor(value.length) && typeof value.every === "function")
}
