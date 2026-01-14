enum PropertyType { villa, apartment, land }

class Property {
  final String id;
  final String ownerId;

  // ✅ اسم المعلن (من users_profiles.username أو properties.username)
  final String? ownerUsername;

  final String title;
  final PropertyType type;
  final String description;

  /// عندك DB لا يوجد location، لذلك نستخدم city أو merged نصياً
  final String location;

  final double area; // m2
  final double price; // SAR

  final bool isAuction;
  final double? currentBid;

  final List<String> images; // urls or assets paths

  final int views;
  final DateTime createdAt;

  // ✅ إحداثيات DB
  final double? latitude;
  final double? longitude;

  Property({
    required this.id,
    required this.ownerId,
    required this.title,
    required this.type,
    required this.description,
    required this.location,
    required this.area,
    required this.price,
    required this.isAuction,
    this.currentBid,
    required this.images,
    required this.views,
    required this.createdAt,
    this.ownerUsername,
    this.latitude,
    this.longitude,
  });
}
