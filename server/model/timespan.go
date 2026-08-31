package model

import "time"

// TimeSpan is basically a tagged time range.
type TimeSpan struct {
	ID            int `gorm:"primary_key;unique_index;AUTO_INCREMENT"`
	StartUTC      time.Time
	EndUTC        *time.Time
	StartUserTime time.Time
	EndUserTime   *time.Time
	OffsetUTC     int
	UserID        int `gorm:"type:int REFERENCES users(id) ON DELETE CASCADE"`
	Tags          []TimeSpanTag
	Note          string
	// UpdatedAtUTC is the server time of the last write, truncated to whole
	// seconds so it round-trips through RFC3339 exactly. It drives the
	// timeSpanChanges delta feed and last-writer-wins sync. Managed
	// explicitly by the write paths, not by gorm.
	UpdatedAtUTC time.Time
}

// TimeSpanTag is a tag for a time range
type TimeSpanTag struct {
	TimeSpanID int `gorm:"type:int REFERENCES time_spans(id) ON DELETE CASCADE"`
	// Position orders the tags within their span (ascending). Rows that
	// predate the column are backfilled on startup (see database.New).
	Position    int
	Key         string
	StringValue string
}
