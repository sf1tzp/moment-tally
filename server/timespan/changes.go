// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Steven Fitzpatrick

package timespan

import (
	"context"

	"momenttally.com/server/auth"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// changesMaxLimit caps (and defaults) the page size of TimeSpanChanges.
const changesMaxLimit = 200

// TimeSpanChanges is the sync delta feed: every timespan written strictly
// after the (since, afterId) checkpoint, ordered by (updatedAt, id)
// ascending, plus tombstones of deletions at or after `since`. Clients walk
// it by feeding the last returned span's (updatedAt, id) back in while
// hasMore is true. UpdatedAtUTC is whole seconds (see syncNow), so a
// checkpoint that has round-tripped through RFC3339 still compares exactly
// — without that, a page full of same-second writes could never advance.
func (r *ResolverForTimeSpan) TimeSpanChanges(ctx context.Context, since model.Time, afterID int, limit *int) (*gqlmodel.TimeSpanChanges, error) {
	userID := auth.GetUser(ctx).ID

	pageSize := changesMaxLimit
	if limit != nil && *limit > 0 && *limit < changesMaxLimit {
		pageSize = *limit
	}

	sinceUTC := since.UTC()
	var spans []model.TimeSpan
	find := preloadTags(r.DB).
		Where("user_id = ?", userID).
		Where("updated_at_utc > ? OR (updated_at_utc = ? AND id > ?)", sinceUTC, sinceUTC, afterID).
		Order("updated_at_utc, id").
		Limit(pageSize + 1).
		Find(&spans)
	if find.Error != nil {
		return nil, find.Error
	}
	hasMore := len(spans) > pageSize
	if hasMore {
		spans = spans[:pageSize]
	}

	// Tombstones are not paged (deletions are rare; re-delivery is
	// harmless, hence >=). A tombstone whose id is live again — sqlite can
	// reuse the highest id after a delete — is stale and must not be
	// delivered, or it would delete the reused span on other devices.
	var tombstones []model.TimeSpanTombstone
	if err := r.DB.
		Where("user_id = ?", userID).
		Where("deleted_at_utc >= ?", sinceUTC).
		Where("time_span_id NOT IN (SELECT id FROM time_spans WHERE user_id = ?)", userID).
		Order("deleted_at_utc, time_span_id").
		Find(&tombstones).Error; err != nil {
		return nil, err
	}

	external := []*gqlmodel.TimeSpan{}
	for _, span := range spans {
		external = append(external, timeSpanToExternal(span))
	}
	deleted := []*gqlmodel.DeletedTimeSpan{}
	for _, tombstone := range tombstones {
		deleted = append(deleted, &gqlmodel.DeletedTimeSpan{
			ID:        tombstone.TimeSpanID,
			DeletedAt: model.Time(tombstone.DeletedAtUTC),
		})
	}

	return &gqlmodel.TimeSpanChanges{
		TimeSpans: external,
		Deleted:   deleted,
		HasMore:   hasMore,
		Now:       model.Time(syncNow()),
	}, nil
}
